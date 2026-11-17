// cmd_diff.c — `diff`，后端用随包的 git。
//
// 为什么不是 GNU diffutils：git 已经在包里，`git diff --no-index` 的输出是标准
// unified diff，退出码语义与 diff 一致（0 相同 / 1 有差异 / 2 出错），而且不需要
// 再引入一套 gnulib。这里只做 argv 转发，exec 走 IEC 的 exec 服务（命令 so 链接
// exec shim，execvp 会被服务接管，不会真的 execve）。
//
// 支持：diff [-u|-U n|-q|-s] a b（选项翻译后交给 git）。
// 注意：git diff 默认输出 unified 格式；需要传统 normal diff 请用 `git diff --no-index`。
//
// 转发时必须把选项放在 `--` 之前：`git diff --no-index -- -u a b` 会把 `-u` 当成
// 路径（退出码 129），选项就全部失效了。
//
// 转发前还要自己挡一遍几种 git 退出码与 diff 约定不一致的情况（git 一律 1 或
// 128/129，diff 约定错误一律 2）：
//   1) 操作数不存在        —— git 返回 1，这里先 stat，报错并返回 2；
//   2) 文件/目录混用且目录里没有同名文件 —— git 返回 1，这里解析成 <dir>/<basename>
//      后 stat，缺了报错返回 2（命名文件存在时 git 能正常比较，不要拦）；
//   3) 操作数不可读        —— git 直接 fatal 返回 128，这里用 access 检查后返回 2；
//   4) 操作数不足 2 个     —— git 打印 usage 返回 129，这里按 diff 约定返回 2；
//   5) -U 后面的上下文长度不是数字 —— git 返回 129，这里按 diff 约定返回 2。
// 其余情况仍然原样转发，diff 算法/输出格式完全由 git 决定，本文件不实现比较逻辑。
//
// 入口 iec_diff_main。
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// git diff 不认识 --version/--help（会以 "error: unknown option" 退出 129），
// 而脚本与包管理器常拿这两个开关探测 diff 是否可用。这里自己回答，不转发。
static const char DIFF_VERSION[] =
    "diff (pocket-harness) 1.0\n"
    "Copyright (C) 2026 pocket-harness-ohos contributors\n"
    "License MIT: <https://opensource.org/licenses/MIT>\n"
    "\n"
    "Backend: git diff --no-index; supports -u, -U NUM, -r, -q and -s.\n";

static const char DIFF_USAGE[] =
    "Usage: diff [OPTION]... FILES\n"
    "Compare FILES line by line.\n"
    "\n"
    "  -u                 output unified context (3 lines by default)\n"
    "  -U NUM             output NUM lines of unified context\n"
    "  -r, --recursive    recursively compare directories\n"
    "  -q, --brief        report only when files differ\n"
    "  -s, --report-identical-files\n"
    "                     report when two files are identical\n"
    "  -v, --version      output version information and exit\n"
    "      --help         display this help and exit\n"
    "\n"
    "This is a git diff --no-index front end; the output format follows git.\n";

// 逐字节比较两个普通文件。返回 1 相同 / 0 不同 / -1 无法判断（目录、打开失败等）。
static int files_identical(const char* a, const char* b) {
    unsigned char ba[65536];
    unsigned char bb[65536];
    struct stat sa;
    struct stat sb;
    FILE* fa;
    FILE* fb;
    int same = 1;

    if (stat(a, &sa) != 0 || stat(b, &sb) != 0) return -1;
    if (!S_ISREG(sa.st_mode) || !S_ISREG(sb.st_mode)) return -1;
    if (sa.st_size != sb.st_size) return 0;
    fa = fopen(a, "rb");
    fb = fopen(b, "rb");
    if (fa == NULL || fb == NULL) {
        if (fa != NULL) fclose(fa);
        if (fb != NULL) fclose(fb);
        return -1;
    }
    for (;;) {
        const size_t na = fread(ba, 1, sizeof ba, fa);
        const size_t nb = fread(bb, 1, sizeof bb, fb);
        if (na != nb || (na > 0 && memcmp(ba, bb, na) != 0)) {
            same = 0;
            break;
        }
        if (na == 0) break;
    }
    fclose(fa);
    fclose(fb);
    return same;
}

// 全是十进制数字才算合法的上下文长度（diff 的 -U 只认非负整数）。
static int is_number(const char* s) {
    if (*s == '\0') return 0;
    for (; *s != '\0'; s++) {
        if (*s < '0' || *s > '9') return 0;
    }
    return 1;
}

// 取路径最后一段（忽略结尾的 '/'），返回指向 path 内部的指针。
static const char* base_name(const char* path) {
    const char* end = path + strlen(path);
    const char* p;

    while (end > path && end[-1] == '/') end--;
    p = end;
    while (p > path && p[-1] != '/') p--;
    return p;
}

// 拼 <dir>/<basename(file)>；返回 malloc 的串，失败返回 NULL。
static char* join_dir_file(const char* dir, const char* file) {
    const char* base = base_name(file);
    size_t dl = strlen(dir);
    size_t bl = strlen(base);
    char* out;

    while (dl > 1 && dir[dl - 1] == '/') dl--;
    out = (char*)malloc(dl + bl + 2);
    if (out == NULL) return NULL;
    memcpy(out, dir, dl);
    out[dl] = '/';
    memcpy(out + dl + 1, base, bl + 1);
    return out;
}

// 这个操作数是不是“读不了”。目录还要求可搜索。设备/管道等特殊文件交给 git。
static int no_read_access(const char* path, const struct stat* st) {
    if (S_ISREG(st->st_mode)) return access(path, R_OK) != 0;
    if (S_ISDIR(st->st_mode)) return access(path, R_OK | X_OK) != 0;
    return 0;
}

// 转发前的检查。返回 0 表示继续交给 git，2 表示已经报错。
static int check_operands(const char* a, const char* b) {
    struct stat sa;
    struct stat sb;
    struct stat st;
    const char* fa = a;
    const char* fb = b;
    char* resolved = NULL;
    int rc = 0;

    if (stat(a, &sa) != 0) {
        fprintf(stderr, "diff: %s: %s\n", a, strerror(errno));
        return 2;
    }
    if (stat(b, &sb) != 0) {
        fprintf(stderr, "diff: %s: %s\n", b, strerror(errno));
        return 2;
    }

    // 文件 vs 目录：diff 的规矩是拿文件去比 <目录>/<文件名>。git 也这么做，
    // 但目录里没有同名文件时 git 只给 1（error: Could not access），要改成 2。
    if (S_ISDIR(sa.st_mode) != S_ISDIR(sb.st_mode)) {
        const char* dir = S_ISDIR(sa.st_mode) ? a : b;
        const char* other = S_ISDIR(sa.st_mode) ? b : a;

        resolved = join_dir_file(dir, other);
        if (resolved == NULL) {
            fprintf(stderr, "diff: out of memory\n");
            return 2;
        }
        if (stat(resolved, &st) != 0) {
            fprintf(stderr, "diff: %s: %s\n", resolved, strerror(errno));
            free(resolved);
            return 2;
        }
        if (S_ISDIR(sa.st_mode)) {
            fb = resolved;
            sb = st;
        } else {
            fa = resolved;
            sa = st;
        }
    }

    if (no_read_access(fa, &sa)) {
        fprintf(stderr, "diff: %s: %s\n", fa, strerror(EACCES));
        rc = 2;
    } else if (no_read_access(fb, &sb)) {
        fprintf(stderr, "diff: %s: %s\n", fb, strerror(EACCES));
        rc = 2;
    }

    free(resolved);
    return rc;
}

int iec_diff_main(int argc, char** argv) {
    // git diff --no-index [options] -- <path> <path>
    char** args;
    char** opts;
    char** paths;
    char** owned;
    int n = 0;
    int nopt = 0;
    int npath = 0;
    int nowned = 0;
    int report_same = 0;
    int endopts = 0;
    int ret = 0;
    int i;

    args = (char**)calloc((size_t)argc + 8, sizeof(char*));
    opts = (char**)calloc((size_t)argc + 1, sizeof(char*));
    paths = (char**)calloc((size_t)argc + 1, sizeof(char*));
    owned = (char**)calloc((size_t)argc + 1, sizeof(char*));
    if (args == NULL || opts == NULL || paths == NULL || owned == NULL) {
        fprintf(stderr, "diff: out of memory\n");
        free(args);
        free(opts);
        free(paths);
        free(owned);
        return 2;
    }

    for (i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (!endopts && strcmp(a, "--") == 0) {
            endopts = 1;
            continue;
        }
        // --version/--help 是标准的探测开关，交给我们自己回答，git 不认识它们。
        if (!endopts && (strcmp(a, "--version") == 0 || strcmp(a, "-v") == 0)) {
            fputs(DIFF_VERSION, stdout);
            goto done;
        }
        if (!endopts && (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0)) {
            fputs(DIFF_USAGE, stdout);
            goto done;
        }
        if (!endopts && (strcmp(a, "-r") == 0 || strcmp(a, "--recursive") == 0)) {
            // git diff --no-index 对目录默认递归，没有 -r 开关；接受 GNU 的写法，
            // 但不转发，否则 git 会以 `unknown switch 'r'` 退出。
            continue;
        }
        if (!endopts && strcmp(a, "-q") == 0) {
            opts[nopt++] = (char*)"--quiet";
            continue;
        }
        if (!endopts && strcmp(a, "-s") == 0) {
            // git 的 -s 是 --no-patch，语义不同；-s 由本进程判断，不转发。
            report_same = 1;
            continue;
        }
        if (!endopts && (strcmp(a, "-U") == 0 || strncmp(a, "-U", 2) == 0)) {
            // GNU diff 允许 `-U n` 分开写，git 只认 `-Un`，这里拼起来。
            // 长度必须是数字：git 对非数字返回 129，diff 约定是 2。
            if (a[2] != '\0') {
                if (!is_number(a + 2)) {
                    fprintf(stderr, "diff: invalid context length '%s'\n", a + 2);
                    ret = 2;
                    goto done;
                }
                opts[nopt++] = argv[i];
            } else {
                size_t len;
                char* combined;

                if (i + 1 >= argc) {
                    fprintf(stderr, "diff: option requires an argument -- 'U'\n");
                    ret = 2;
                    goto done;
                }
                if (!is_number(argv[i + 1])) {
                    fprintf(stderr, "diff: invalid context length '%s'\n", argv[i + 1]);
                    ret = 2;
                    goto done;
                }
                len = strlen(argv[i + 1]) + 3;
                combined = (char*)malloc(len);
                if (combined == NULL) {
                    fprintf(stderr, "diff: out of memory\n");
                    ret = 2;
                    goto done;
                }
                snprintf(combined, len, "-U%s", argv[++i]);
                opts[nopt++] = combined;
                owned[nowned++] = combined;
            }
            continue;
        }
        if (!endopts && a[0] == '-' && a[1] != '\0') {
            opts[nopt++] = argv[i];
            continue;
        }
        paths[npath++] = argv[i];
    }

    // 与 GNU diff 对齐：操作数不足报错并返回 2（git 只打印 usage 返回 129）。
    if (npath < 2) {
        fprintf(stderr, "diff: missing operand after '%s'\n",
                argc > 1 ? argv[argc - 1] : argv[0]);
        fprintf(stderr, "diff: Try 'diff --help' for more information.\n");
        ret = 2;
        goto done;
    }

    // 与 GNU diff 对齐：操作数不存在/不可读返回 2（git 是 1 或 128）。
    ret = check_operands(paths[0], paths[1]);
    if (ret != 0) goto done;

    if (report_same && files_identical(paths[0], paths[1]) == 1) {
        printf("Files %s and %s are identical\n", paths[0], paths[1]);
        goto done;
    }

    args[n++] = (char*)"git";
    args[n++] = (char*)"diff";
    args[n++] = (char*)"--no-index";
    for (i = 0; i < nopt; i++) args[n++] = opts[i];
    args[n++] = (char*)"--";
    for (i = 0; i < npath; i++) args[n++] = paths[i];
    args[n] = NULL;

    execvp("git", args);
    fprintf(stderr, "diff: cannot run git: %s\n", strerror(errno));
    ret = 2;

done:
    // 命令 so 常驻在 shell 进程里，错误/identicals 分支返回前要还内存，
    // 否则每调一次 diff 就漏一小块。
    for (i = 0; i < nowned; i++) free(owned[i]);
    free(owned);
    free(args);
    free(opts);
    free(paths);
    return ret;
}
