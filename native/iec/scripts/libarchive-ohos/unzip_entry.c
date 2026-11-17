// scripts/libarchive-ohos/unzip_entry.c — Info-ZIP `unzip -v` compatibility
// wrapper around libarchive's bsdunzip front end.
//
// bsdunzip's getopt table has no -v/--version, so `unzip -v` (the usual "is
// unzip installed?" probe, and Info-ZIP's verbose-listing mode) fell through to
// the usage text. This wrapper answers the version probe itself and rewrites
// `-v` to `-l` for the "list an archive in detail" case, which is the closest
// libarchive equivalent. Everything else is forwarded unchanged.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <archive.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// bsdunzip.c is compiled with -Dmain=iec_bsdunzip_real_main.
int iec_bsdunzip_real_main(int argc, char** argv);

// Whether the command line names an archive operand (anything after the options
// that is not consumed by an option argument).
static int HasArchiveOperand(int argc, char** argv)
{
    int endopts = 0;

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];

        if (!endopts && strcmp(a, "--") == 0) {
            endopts = 1;
            continue;
        }
        if (!endopts && a[0] == '-' && a[1] != '\0') {
            // -d takes a separate directory argument.
            if (strcmp(a, "-d") == 0 && i + 1 < argc) i++;
            continue;
        }
        return 1;
    }
    return 0;
}

static void PrintVersion(void)
{
    printf("Pocket Harness unzip 1.0 (libarchive %s)\n", archive_version_string());
    printf("Usage: unzip [-lqv] archive.zip [file...]\n");
}

int iec_bsdunzip_main(int argc, char** argv)
{
    int version = 0;

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];

        if (strcmp(a, "--") == 0) break;
        if (strcmp(a, "--version") == 0) {
            version = 1;
            continue;
        }
        if (a[0] != '-' || a[1] == '\0') break;
        if (strcmp(a, "-d") == 0) {
            i++;
            continue;
        }
        // Bundled short options: -qv, -lv, ...
        for (const char* p = a + 1; *p; p++) {
            if (*p == 'v') version = 1;
        }
    }

    if (!version) return iec_bsdunzip_real_main(argc, argv);
    if (!HasArchiveOperand(argc, argv)) {
        PrintVersion();
        return 0;
    }

    // `unzip -v archive` lists the archive in detail: map -v to -l and hand the
    // rest to bsdunzip. New option strings are heap-allocated because bsdunzip
    // keeps pointers into argv; they are released after it returns.
    char** nargv = (char**)calloc((size_t)argc + 2, sizeof(char*));
    if (nargv == NULL) return iec_bsdunzip_real_main(argc, argv);
    int n = 0;
    int allocated = 0;
    int have_list = 0;
    char** owned = (char**)calloc((size_t)argc + 1, sizeof(char*));
    nargv[n++] = argv[0];
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];

        if (a[0] == '-' && a[1] != '\0' && strncmp(a, "--", 2) != 0 && strchr(a, 'v')) {
            if (strcmp(a, "-v") == 0) {
                nargv[n++] = (char*)"-l";
                have_list = 1;
                continue;
            }
            char* s = (char*)malloc(strlen(a) + 1);
            if (s == NULL) continue;
            size_t k = 0;
            s[k++] = '-';
            for (const char* p = a + 1; *p; p++) {
                if (*p != 'v') s[k++] = *p;
            }
            s[k] = '\0';
            if (k == 1) {
                free(s);
            } else {
                nargv[n++] = s;
                if (owned != NULL) owned[allocated++] = s;
            }
            continue;
        }
        nargv[n++] = argv[i];
    }
    if (!have_list) nargv[n++] = (char*)"-l";
    nargv[n] = NULL;

    const int rc = iec_bsdunzip_real_main(n, nargv);
    for (int i = 0; i < allocated; i++) free(owned[i]);
    free(owned);
    free(nargv);
    return rc;
}
