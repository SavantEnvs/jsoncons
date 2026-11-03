#!/usr/bin/env bash
#
# mayhem/build.sh — build jsoncons' fuzz harnesses (fuzzers/fuzz_*.cpp, the OSS-Fuzz set) and its
# Catch unit-test suite. Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline
# (jsoncons is header-only and has no build-time downloads).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS STANDALONE_FUZZ_MAIN SRC

cd "$SRC"

# 1) Harnesses. The library is header-only, so compiling each harness with $SANITIZER_FLAGS instruments
#    the fuzzed code. Each harness is linked twice: libFuzzer binary + run-once standalone reproducer.
OBJ="$SRC/build/fuzz-objs"
mkdir -p "$OBJ"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"

build_one() {
  local src="$1" name
  name="$(basename "$src" .cpp)"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC/include" "$src" "$OBJ/lsan_off.o" $LIB_FUZZING_ENGINE \
      -o "$SRC/$name"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC/include" "$src" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" \
      -o "$SRC/$name-standalone"
}
export -f build_one
export OBJ

ls "$SRC"/fuzzers/fuzz_*.cpp | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'build_one {}'

# 2) Unit-test suite with the project's NORMAL flags (clean, independent build; no sanitizers/DWARF pin).
#    `build/` is gitignored upstream (**/build), so a `git clean -ffdX` removes it.
#    Upstream's test/CMakeLists.txt builds with `-Werror -pedantic`, and clang 19 rejects Catch's empty
#    variadic macro argument as a C++20 extension. Those flags come last on the compile line, so no
#    CMAKE_CXX_FLAGS can silence it; CCC_OVERRIDE_OPTIONS appends -Wno-c++20-extensions after them
#    (one diagnostic, tests only, compiler still resolved by name).
export CCC_OVERRIDE_OPTIONS="+-Wno-c++20-extensions"
env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
  cmake -S "$SRC" -B "$SRC/build/tests" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DJSONCONS_BUILD_TESTS=ON "-DCMAKE_CXX_FLAGS=$COVERAGE_FLAGS"
env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
  cmake --build "$SRC/build/tests" --target unit_tests -j"$MAYHEM_JOBS"
