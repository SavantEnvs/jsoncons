#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the Catch2 unit_tests binary that build.sh produced. Its cwd must be test/ (data files are
# referenced relatively). The summary line is parsed for counts; a missing summary (crash, neutered
# binary) counts as a failure.
RUNNER="$SRC/build/tests/test/unit_tests"
[ -x "$RUNNER" ] || { echo "unit_tests missing: mayhem/build.sh did not build it" >&2; emit_ctrf "catch2" 0 1 0; exit 1; }

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
(cd "$SRC/test" && "$RUNNER") >"$OUT" 2>&1
tail -n 15 "$OUT"

passed=0 ; failed=0
if grep -q '^All tests passed' "$OUT"; then
  # "All tests passed (N assertions in M test cases)"
  passed="$(sed -n 's/^All tests passed (.* in \([0-9]*\) test case.*/\1/p' "$OUT" | tail -n1)"
elif grep -q '^test cases:' "$OUT"; then
  # "test cases: T | P passed | F failed"
  line="$(grep '^test cases:' "$OUT" | tail -n1)"
  passed="$(sed -n 's/.*| *\([0-9]*\) passed.*/\1/p' <<<"$line")"
  failed="$(sed -n 's/.*| *\([0-9]*\) failed.*/\1/p' <<<"$line")"
fi
passed="${passed:-0}" ; failed="${failed:-0}"
# No parsable summary (or zero tests run) is a failure, never a pass.
if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
emit_ctrf "catch2" "$passed" "$failed" 0
