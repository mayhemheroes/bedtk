#!/usr/bin/env bash
# bedtk/mayhem/test.sh — GOLDEN / known-answer oracle for lh3/bedtk.
#
# bedtk ships NO unit-test suite (its Makefile has no test target; test/ holds only sample BED/VCF
# data). The README, however, documents a fixed set of canonical example invocations against that
# bundled data. We turn those documented invocations into a known-answer functional oracle:
#
#   * This script builds bedtk INDEPENDENTLY with the project's NORMAL flags (`make` — the same
#     -O2 -std=c99 build upstream documents), NOT the sanitizer/fuzz build that mayhem/build.sh
#     produces. Using the normal flags means the oracle exercises the real, shipped behavior and
#     will not false-fail on benign UB that the fuzz build's UBSan would halt on.
#   * It then RUNS each documented subcommand and DIFFs its stdout against a committed golden file
#     (mayhem/testdata/golden/<name>.out). The goldens were captured once from this freshly-built
#     binary; the README guarantees these are the canonical example invocations, and every case
#     was verified byte-stable across repeated runs.
#
# This is a PATCH-grade, anti-reward-hack oracle by construction: it asserts the EXACT computed
# OUTPUT of each subcommand, not merely "exited 0". A no-op / exit(0) "patch", or any change that
# stops bedtk emitting correct interval results, produces empty or mismatched output and FAILS the
# diff. Every case here exercises the BED/VCF parser + cgranges implicit-interval-tree code.
set -uo pipefail

# clang/gcc reject SOURCE_DATE_EPOCH='' (empty); must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

# SRC is /mayhem in the commit image; default to this checkout's repo root so the suite also runs
# straight from a developer checkout (mayhem/ is one level below the repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SRC:=$(cd "$HERE/.." && pwd)}"
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

GOLDEN="$SRC/mayhem/testdata/golden"
[ -d "$GOLDEN" ] || { echo "missing golden dir $GOLDEN — wrong tree?" >&2; emit_ctrf "bedtk-golden" 0 1; exit 2; }
[ -f "$SRC/test/test-anno.bed.gz" ] || { echo "missing test fixtures under $SRC/test — wrong tree?" >&2; emit_ctrf "bedtk-golden" 0 1; exit 2; }

# Build bedtk INDEPENDENTLY with the project's NORMAL flags (NOT the sanitizer/fuzz build). bedtk's
# Makefile hard-codes the output name `bedtk` (PROG is not honored by the explicit link rule), so we
# `make` the default target and then stage the resulting binary to a private path (BIN) — this keeps
# the oracle independent of whatever mayhem/build.sh produced (it builds /mayhem/fuzz_bedtk, not
# ./bedtk). `make -B` forces a fresh compile so stale objects can't mask a build regression.
: "${CC:=gcc}"
export CC
BIN="$SRC/bedtk-test"
make -B -j"$MAYHEM_JOBS" >/tmp/bedtk-test-build.log 2>&1 || {
  echo "test.sh: normal-flags build failed:" >&2; tail -40 /tmp/bedtk-test-build.log >&2
  emit_ctrf "bedtk-golden" 0 1; exit 2
}
[ -x "$SRC/bedtk" ] || { echo "test.sh: build produced no ./bedtk" >&2; emit_ctrf "bedtk-golden" 0 1; exit 2; }
cp -f "$SRC/bedtk" "$BIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0

# run_case <name> <subcommand args...>
# Runs `bedtk <args>`, diffs stdout against mayhem/testdata/golden/<name>.out. The subcommand MUST
# exit 0 AND match the golden byte-for-byte, else the case fails.
run_case() {
  local name="$1"; shift
  local gold="$GOLDEN/$name.out" got="$WORK/$name.out" rc
  if [ ! -f "$gold" ]; then
    echo "FAIL $name: missing golden $gold" >&2; failed=$((failed+1)); return
  fi
  "$BIN" "$@" > "$got" 2>"$WORK/$name.err"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name: bedtk $* exited $rc (expected 0)" >&2
    sed 's/^/    /' "$WORK/$name.err" >&2
    failed=$((failed+1)); return
  fi
  if diff -u "$gold" "$got" > "$WORK/$name.diff" 2>&1; then
    echo "PASS $name"; passed=$((passed+1))
  else
    echo "FAIL $name: output differs from golden" >&2
    head -20 "$WORK/$name.diff" | sed 's/^/    /' >&2
    failed=$((failed+1))
  fi
}

# The README's documented canonical invocations (run from the repo root, against test/ fixtures).
run_case flt        flt    test/test-anno.bed.gz test/test-iso.bed.gz
run_case flt_v      flt -v test/test-anno.bed.gz test/test-iso.bed.gz
run_case flt_cw100  flt -cw100 test/test-anno.bed.gz test/test-sub.vcf.gz
run_case isec       isec   test/test-anno.bed.gz test/test-iso.bed.gz
run_case cov        cov    test/test-anno.bed.gz test/test-iso.bed.gz
run_case sort       sort   test/test-iso.bed.gz
run_case sort_s     sort -s test/chr_list.txt test/test-iso.bed.gz
run_case merge      merge  test/test-anno.bed.gz

emit_ctrf "bedtk-golden" "$passed" "$failed"
