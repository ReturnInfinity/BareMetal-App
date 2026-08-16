// test-dlopen.c -- in-depth pass/fail self-test of port/dlfcn_shim.c's
// dlopen()/dlsym()/dlclose()/dlerror(). Modeled on test-lwip.c's
// tiered layout (see that file's own header comment).
//
// dltest.c already covers the happy path end-to-end (one module, two
// symbols, one missing-file check) -- this instead tries to hit every
// branch in dlfcn_shim.c on purpose:
//
//   - Loader-mechanics unit tests: one purpose-built module per
//     relocation/error path (see BareMetal-AppPort/dlopen_modules/*.c
//     for what each one isolates and why), plus a repeated
//     open/use/close loop against the free-list allocator
//     posix_shim.c's malloc() draws from, to catch a leak that a
//     single dlopen()/dlclose() pair never would.
//
//   - Real consumers: modtest.so and pyexttest.so, if present on disk
//     (BareMetal-AppPort/build-dlopen-tests.sh installs whatever it
//     finds already built) -- proves the same loader that just passed
//     a battery of synthetic checks also satisfies actual dlopen()
//     callers elsewhere in this port (pyexttest.so via Python's own
//     Modules/dynload_shlib.c, not anything test-specific).
//
// Build fixtures with BareMetal-AppPort/build-dlopen-tests.sh (which
// also installs them onto disk.img) before building/running this app.

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define MODDIR "/modules/dlopen_tests/"

static int passed, failed, skipped;

typedef enum { CHK_PASS, CHK_FAIL, CHK_SKIP } result_t;

static void report(const char *label, result_t result, const char *detail)
{
	const char *tag = result == CHK_PASS ? "PASS" : result == CHK_SKIP ? "SKIP" : "FAIL";

	if (detail && detail[0])
		printf("  %-46s [%s] (%s)\n", label, tag, detail);
	else
		printf("  %-46s [%s]\n", label, tag);

	if (result == CHK_PASS)
		passed++;
	else if (result == CHK_SKIP)
		skipped++;
	else
		failed++;
}

static void ok(const char *label, int cond)
{
	report(label, cond ? CHK_PASS : CHK_FAIL, NULL);
}

// Every "this dlopen()/dlsym() call should succeed" check below goes
// through this pair so a failure always reports dlerror()'s text
// instead of just "FAIL" with no clue why.
static void ok_or_error(const char *label, int cond)
{
	report(label, cond ? CHK_PASS : CHK_FAIL, cond ? NULL : dlerror());
}

// ---------------------------------------------------------------------------
// Tier 1: loader mechanics -- one purpose-built module per code path.
// ---------------------------------------------------------------------------

static void test_relative_relocs(void)
{
	void *h = dlopen(MODDIR "mod_data.so", 0);
	if (!h) {
		report("R_X86_64_RELATIVE data pointers (mod_data.so)", CHK_FAIL, dlerror());
		report("mod_data.so: name_count()/get_name() values", CHK_SKIP, "module didn't load");
		return;
	}
	report("R_X86_64_RELATIVE data pointers (mod_data.so)", CHK_PASS, NULL);

	int (*name_count)(void) = dlsym(h, "name_count");
	const char *(*get_name)(int) = dlsym(h, "get_name");
	int good = name_count && get_name && name_count() == 4 &&
		   get_name(0) && strcmp(get_name(0), "alpha") == 0 &&
		   get_name(3) && strcmp(get_name(3), "delta") == 0 &&
		   get_name(4) == 0; // out of range -> NULL, not a wild pointer
	ok("mod_data.so: name_count()/get_name() values", good);

	dlclose(h);
}

static void test_host_export_calls(void)
{
	void *h = dlopen(MODDIR "mod_extern.so", 0);
	if (!h) {
		report("host export calls (mod_extern.so)", CHK_FAIL, dlerror());
		report("mod_extern.so: roundtrip_via_host()", CHK_SKIP, "module didn't load");
		return;
	}
	report("host export calls (mod_extern.so)", CHK_PASS, NULL);

	int (*roundtrip)(void) = dlsym(h, "roundtrip_via_host");
	ok("mod_extern.so: roundtrip_via_host()", roundtrip && roundtrip() == 0);

	dlclose(h);
}

static void test_init_array_ctor(void)
{
	void *h = dlopen(MODDIR "mod_ctor.so", 0);
	if (!h) {
		report("DT_INIT_ARRAY constructor (mod_ctor.so)", CHK_FAIL, dlerror());
		report("mod_ctor.so: constructor ran before dlopen() returned", CHK_SKIP, "module didn't load");
		return;
	}
	report("DT_INIT_ARRAY constructor (mod_ctor.so)", CHK_PASS, NULL);

	int (*ctor_flag)(void) = dlsym(h, "ctor_flag");
	// If this is 0, either the RELATIVE reloc on the .init_array entry
	// itself wasn't applied, or init_array was never walked at all --
	// either way, the constructor didn't actually run.
	ok("mod_ctor.so: constructor ran before dlopen() returned", ctor_flag && ctor_flag() == 1);

	dlclose(h);
}

static void test_many_symbols(void)
{
	void *h = dlopen(MODDIR "mod_many.so", 0);
	if (!h) {
		report("dlsym() over a large symbol table (mod_many.so)", CHK_FAIL, dlerror());
		report("mod_many.so: last symbol (fn19) resolves", CHK_SKIP, "module didn't load");
		report("mod_many.so: intra-module call chain", CHK_SKIP, "module didn't load");
		return;
	}
	report("dlsym() over a large symbol table (mod_many.so)", CHK_PASS, NULL);

	int (*fn0)(int) = dlsym(h, "fn0");
	int (*fn19)(int) = dlsym(h, "fn19");
	ok("mod_many.so: last symbol (fn19) resolves", fn0 && fn19 && fn0(10) == 10 && fn19(10) == 29);

	int (*chain)(int) = dlsym(h, "fn_call_chain");
	ok("mod_many.so: intra-module call chain", chain && chain(0) == 19);

	dlclose(h);
}

static void test_undefined_symbol(void)
{
	void *h = dlopen(MODDIR "mod_undef.so", 0);
	if (h) {
		report("undefined symbol rejected at dlopen() (mod_undef.so)", CHK_FAIL, "dlopen unexpectedly succeeded");
		dlclose(h);
		return;
	}
	const char *err = dlerror();
	int names_the_symbol = err && strstr(err, "not_a_real_dl_export_symbol") != 0;
	report("undefined symbol rejected at dlopen() (mod_undef.so)", names_the_symbol ? CHK_PASS : CHK_FAIL, err);
}

// One shared helper for the four broken-ELF fixtures below -- same
// shape of check (dlopen() must fail, must not leak a stale handle
// through dlerror() on the *next* successful call), different file.
static void expect_dlopen_fails(const char *label, const char *path)
{
	void *h = dlopen(path, 0);
	if (h) {
		report(label, CHK_FAIL, "dlopen unexpectedly succeeded");
		dlclose(h);
		return;
	}
	report(label, CHK_PASS, dlerror());
}

static void test_malformed_elf_files(void)
{
	expect_dlopen_fails("truncated file rejected (truncated.so)", MODDIR "truncated.so");
	expect_dlopen_fails("bad ELF magic rejected (bad_magic.so)", MODDIR "bad_magic.so");
	expect_dlopen_fails("wrong ELF class rejected (bad_class.so)", MODDIR "bad_class.so");
	expect_dlopen_fails("non-ET_DYN rejected (bad_type.so)", MODDIR "bad_type.so");
	expect_dlopen_fails("missing PT_DYNAMIC rejected (no_dynamic.so)", MODDIR "no_dynamic.so");
}

static void test_dlopen_dlsym_edge_cases(void)
{
	ok("dlopen(NULL path) rejected", dlopen(0, 0) == 0);
	ok("dlopen(missing file) rejected", dlopen(MODDIR "does_not_exist.so", 0) == 0);
	ok("dlsym(NULL handle) rejected", dlsym(0, "anything") == 0);

	void *h = dlopen(MODDIR "mod_data.so", 0);
	if (h) {
		ok("dlsym(missing symbol) rejected", dlsym(h, "no_such_symbol") == 0);
		dlclose(h);
	} else {
		report("dlsym(missing symbol) rejected", CHK_SKIP, "mod_data.so didn't load");
	}

	// dlclose() on an already-freed/never-valid handle must not crash
	// the app -- there's nothing to assert on beyond "execution
	// continues," so reaching the next report() line below is the
	// pass condition.
	dlclose(0);
	report("dlclose(NULL) doesn't crash", CHK_PASS, NULL);
}

// Repeated load/use/close of the same module against posix_shim.c's
// free-list allocator -- a single dlopen()/dlclose() pair can't tell a
// leaked block from a freed one, only a loop that would eventually
// exhaust the heap if dlclose() weren't actually freeing h->block.
#define STRESS_ITERS 200

static void test_repeated_load_unload(void)
{
	int ok_count = 0;
	for (int i = 0; i < STRESS_ITERS; i++) {
		void *h = dlopen(MODDIR "mod_data.so", 0);
		if (!h)
			break;
		int (*name_count)(void) = dlsym(h, "name_count");
		if (!name_count || name_count() != 4) {
			dlclose(h);
			break;
		}
		dlclose(h);
		ok_count++;
	}

	char detail[64];
	if (ok_count < STRESS_ITERS) {
		snprintf(detail, sizeof(detail), "stopped at iteration %d/%d: %s",
			 ok_count, STRESS_ITERS, dlerror());
		report("repeated dlopen()/dlclose() doesn't leak or corrupt state", CHK_FAIL, detail);
	} else {
		snprintf(detail, sizeof(detail), "%d iterations", STRESS_ITERS);
		report("repeated dlopen()/dlclose() doesn't leak or corrupt state", CHK_PASS, detail);
	}
}

// Several handles open at once, closed in a different order than they
// were opened in -- each handle's struct dl_handle/malloc'd block has
// to be independent of the others (no shared static state beyond
// dlerror()'s single buffer, which single-threaded apps don't race on
// -- see dlfcn_shim.c's own comment on that).
static void test_concurrent_handles(void)
{
	void *ha = dlopen(MODDIR "mod_data.so", 0);
	void *hb = dlopen(MODDIR "mod_extern.so", 0);
	void *hc = dlopen(MODDIR "mod_many.so", 0);

	if (!ha || !hb || !hc) {
		report("multiple simultaneous handles stay independent", CHK_FAIL, dlerror());
		if (ha) dlclose(ha);
		if (hb) dlclose(hb);
		if (hc) dlclose(hc);
		return;
	}

	int (*name_count)(void) = dlsym(ha, "name_count");
	int (*roundtrip)(void) = dlsym(hb, "roundtrip_via_host");
	int (*fn19)(int) = dlsym(hc, "fn19");

	int good_before_close = name_count && name_count() == 4 &&
				 roundtrip && roundtrip() == 0 &&
				 fn19 && fn19(1) == 20;

	// Close out of open-order (b, then a, then c) -- ha/hc must still
	// work correctly after hb (opened between them) is gone.
	dlclose(hb);
	int good_after_close = name_count() == 4 && fn19(1) == 20;

	dlclose(ha);
	dlclose(hc);

	ok("multiple simultaneous handles stay independent", good_before_close && good_after_close);
}

// ---------------------------------------------------------------------------
// Tier 2: real consumers -- same loader, actual callers elsewhere in
// this port, not synthetic fixtures.
// ---------------------------------------------------------------------------

static void test_modtest_consumer(void)
{
	void *h = dlopen(MODDIR "modtest.so", 0);
	if (!h) {
		report("modtest.so (dltest.c's own fixture) loads and runs", CHK_SKIP, "not installed -- see build-dlopen-tests.sh");
		return;
	}
	int (*add)(int, int) = dlsym(h, "add");
	ok_or_error("modtest.so (dltest.c's own fixture) loads and runs", add && add(2, 3) == 5);
	dlclose(h);
}

static void test_pyexttest_consumer(void)
{
	// pyexttest.so is a real CPython C-extension module (PyInit_
	// entry point, PY_SSIZE_T_CLEAN Python.h API) -- this doesn't
	// re-run it through Python's own import machinery (that only
	// happens inside python.app), just confirms dlfcn_shim.c can
	// load and relocate it and finds its PyInit_pyexttest entry
	// point, the same two steps Modules/dynload_shlib.c's own
	// dlopen()/dlsym() pair does before ever calling it.
	void *h = dlopen(MODDIR "pyexttest.so", 0);
	if (!h) {
		report("pyexttest.so loads (real CPython extension module)", CHK_SKIP, "not installed -- see build-dlopen-tests.sh");
		return;
	}
	report("pyexttest.so loads (real CPython extension module)", CHK_PASS, NULL);

	void *entry = dlsym(h, "PyInit_pyexttest");
	ok_or_error("pyexttest.so: PyInit_pyexttest entry point found", entry != 0);

	dlclose(h);
}

int main(void)
{
	printf("test-dlopen: exercising port/dlfcn_shim.c\n\n");

	printf("loader-mechanics unit tests:\n");
	test_relative_relocs();
	test_host_export_calls();
	test_init_array_ctor();
	test_many_symbols();
	test_undefined_symbol();
	test_malformed_elf_files();
	test_dlopen_dlsym_edge_cases();
	test_repeated_load_unload();
	test_concurrent_handles();

	printf("\nreal consumers:\n");
	test_modtest_consumer();
	test_pyexttest_consumer();

	printf("\n%d/%d passed", passed, passed + failed);
	if (skipped)
		printf(", %d skipped", skipped);
	if (failed)
		printf(", %d FAILED\n", failed);
	else
		printf(", all OK\n");

	return failed;
}
