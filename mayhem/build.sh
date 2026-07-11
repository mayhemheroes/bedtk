#!/usr/bin/env bash
# bedtk/mayhem/build.sh — build the sanitized fuzz_bedtk libFuzzer harness (and its standalone
# reproducer) for lh3/bedtk's BED-file parsing surface.
#
# bedtk is a tiny C99 toolkit: bedtk.c (the subcommands + BED/VCF/PAF parsers) + cgranges.c (the
# implicit-interval-tree library), bundling khash/kavl/kseq/ketopt as headers, linked against zlib
# (-lz). The harness (mayhem/fuzz_bedtk.c) calls main_sort() in-process on fuzz bytes, so we compile
# the PROJECT (bedtk.c + cgranges.c) WITH $SANITIZER_FLAGS — the fuzzed code is instrumented, not just
# the harness. bedtk.c is compiled with -Dmain=bedtk_unused_main so its own main() does not collide
# with libFuzzer's / the standalone driver's main.
#
# bedtk has no unit-test suite (no test target in its Makefile, no test framework — test/ holds only
# sample input data), so there is no test build here and the integration ships no mayhem/test.sh.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# bedtk builds with -Wc++-compat -std=c99; keep that so the project compiles as upstream documents.
PROJ_CFLAGS="-std=c99 -Wno-c++-compat -I$SRC"

# 1) Build the PROJECT (the code the harness fuzzes) WITH $SANITIZER_FLAGS so the fuzzed code is
#    instrumented. bedtk.c's main() is renamed so it doesn't collide with the fuzzer entry point.
$CC $SANITIZER_FLAGS $PROJ_CFLAGS -Dmain=bedtk_unused_main -c "$SRC/bedtk.c" -o /tmp/bedtk.san.o
$CC $SANITIZER_FLAGS $PROJ_CFLAGS -c "$SRC/cgranges.c" -o /tmp/cgranges.san.o
ar rcs /tmp/libbedtk.san.a /tmp/bedtk.san.o /tmp/cgranges.san.o

# 2) Compile asan_options.c (bakes detect_leaks=0 into the binary to prevent LSan-under-ptrace
#    aborting with 0 edges in Mayhem's coverage-collection environment — FAQ: LSan-under-ptrace).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/asan_options.c" -o /tmp/asan_options.o

# 2a) The libFuzzer harness (the Mayhem target `bedtk`): harness + engine + sanitized lib + zlib.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $PROJ_CFLAGS \
    "$SRC/mayhem/fuzz_bedtk.c" /tmp/asan_options.o $LIB_FUZZING_ENGINE /tmp/libbedtk.san.a -lz \
    -o /mayhem/fuzz_bedtk

# 2b) Standalone (non-fuzzer) reproducer: same harness + LLVM's run-once driver instead of the
#     engine. C harness, so $STANDALONE_FUZZ_MAIN compiles with $CC. Respects $SANITIZER_FLAGS.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $PROJ_CFLAGS \
    "$SRC/mayhem/fuzz_bedtk.c" /tmp/asan_options.o /tmp/standalone_main.o /tmp/libbedtk.san.a -lz \
    -o /mayhem/fuzz_bedtk-standalone
