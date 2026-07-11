// mayhem/asan_options.c — bake ASan runtime options into the fuzz binary.
//
// Under Mayhem's ptrace-based coverage collection, LSan's clone() syscall (used to fork a
// subprocess that checks for leaks at program exit) is intercepted and can abort, producing
// 0 edges even on a healthy binary (FAQ: LSan-under-ptrace). Disabling leak detection via
// __asan_default_options prevents that abort path; other ASan/UBSan checks remain active.
//
// __asan_default_options is called by the ASan runtime before any instrumented code runs.
// This strong (non-weak) definition overrides ASan's own weak default, so detect_leaks=0
// is effective regardless of how the ASan library is linked.
//
// This file is compiled and linked into every Mayhem fuzz binary by mayhem/build.sh.
const char *__asan_default_options(void) {
	return "detect_leaks=0";
}
