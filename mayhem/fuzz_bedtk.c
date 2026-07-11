// mayhem/fuzz_bedtk.c — libFuzzer harness for lh3/bedtk's BED-file parsing surface.
//
// Ported from the original mayhemheroes integration, whose target `bedtk` fuzzed the real binary
// invoked as `bedtk sort /test.bed.gz` (a file-input target). This in-process libFuzzer harness
// drives the SAME surface — bedtk's BED3 reader/parser (read_bed3b -> parse_bed3b, the cgranges
// interval tree, the sort path) — but feeds the fuzz bytes directly and runs instrumented, so ASan/
// UBSan see every parse. We keep the target name `bedtk` (the old Mayhemfile target) and exercise
// `main_sort`, the subcommand the old harness drove.
//
// bedtk.c is compiled with -Dmain=bedtk_unused_main (build.sh) so its own main() does not collide
// with libFuzzer's. main_sort() and the subcommand entry points stay non-static, so we call one
// directly here. read_bed3b() opens the path with gzopen and transparently handles both plain and
// gzip'd input, so we just write the raw fuzz bytes to a temp file and let bedtk parse them as a BED
// file (the natural, NUL-tolerant, line-oriented surface — exactly what the old file target fed).
// Under -std=c99 the POSIX functions we use (mkstemp, dup/dup2, write, unlink, fileno) are not
// declared by default — request the default feature set so their prototypes are visible.
//
// Scratch path: temp files go to /dev/shm (always writable even in Mayhem's read-only container;
// /tmp and /mayhem are read-only during coverage collection — §6.2 item 13 + FAQ: scratch path).
#define _DEFAULT_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

// bedtk's "sort" subcommand entry point (non-static in bedtk.c). It takes argc/argv where argv[0]
// is the subcommand name ("sort") and the remaining args are options/<in.bed>.
int main_sort(int argc, char *argv[]);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	// Write the fuzz bytes to /dev/shm: always writable in Mayhem's read-only container.
	// /tmp is a read-only bind-mount during coverage collection; /dev/shm (tmpfs) is writable.
	char path[] = "/dev/shm/bedtk_fuzz_XXXXXX";
	int fd = mkstemp(path);
	if (fd < 0) return 0;
	if (size) {
		ssize_t off = 0;
		while ((size_t)off < size) {
			ssize_t w = write(fd, data + off, size - off);
			if (w <= 0) { close(fd); unlink(path); return 0; }
			off += w;
		}
	}
	close(fd);

	// argv[0] = "sort", argv[1] = <input path>. main_sort uses a fresh KETOPT_INIT each call and
	// frees everything it allocates, so it is re-entrant across fuzz iterations.
	// stdout output (sorted BED records) is left on fd 1 — libFuzzer redirects it internally.
	char *argv[] = { (char *)"sort", path, NULL };
	main_sort(2, argv);

	unlink(path);
	return 0;
}
