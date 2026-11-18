#!/bin/bash
# build_tree.sh — build tree(1) as an IEC command object (libtreecmd.so).
#
# tree is a single C file.  The entry is renamed at compile time because the
# program is linked into a shared object and started by the IEC exec service.
#
# Output: platform/ohos/har/libs/arm64-v8a/libtreecmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

TREE_VER="${TREE_VER:-2.2.1}"
# tag 2.2.1 的 commit（api.github.com/repos/Old-Man-Programmer/tree/git/tags/2.2.1）。
TREE_COMMIT="$(iec_sha_or IEC_TREE_COMMIT d501b58ff9cbfd64272c8cbcad0bda36a3fada06)"
TAR="$IEC_THIRDPARTY/tree-$TREE_VER.tar.gz"
# GitHub 归档没有官方 checksum 文件；未固定哈希时普通构建告警，CI 失败。
SHA256="$(iec_sha_or IEC_TREE_SHA256 6daa27cd1f01f1b2d806f1c71b3cb78f896987e197d4215ea834f09373ff5fdf)"
SRC="$IEC_THIRDPARTY/tree-$TREE_VER"
WORK="$IEC_ROOT/build/tree"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK" "$OUT_DIR" "$IEC_THIRDPARTY"
iec_fetch_verified "https://codeload.github.com/Old-Man-Programmer/tree/tar.gz/$TREE_COMMIT" \
	"$TAR" "$SHA256" "tree $TREE_VER"
if [ ! -f "$SRC/tree.c" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"

# tree is split across several translation units (tree.c, file.c, color.c,
# html.c, json.c, list.c, ...); compile them all.  Only tree.c has main().
declare -a TOBJ=()
for src in "$SRC"/*.c; do
	base="$(basename "$src" .c)"
	extra=()
	if [ "$base" = "tree" ]; then extra=(-Dmain=iec_tree_main); fi
	$CC_TARGET -O2 -fPIC -D_GNU_SOURCE "${extra[@]}" \
		-Wno-implicit-function-declaration -Wno-macro-redefined \
		-I "$SRC" -c "$src" -o "$WORK/tree_$base.o"
	TOBJ+=("$WORK/tree_$base.o")
done

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -O2 -fPIC -c "$IEC_ROOT/scripts/optional/compat_strverscmp.c" \
	-o "$WORK/compat_strverscmp.o"
$CC_TARGET -shared -o "$OUT_DIR/libtreecmd.so" "${TOBJ[@]}" "$WORK/compat_strverscmp.o" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libtreecmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libtreecmd.so" \
	| grep ' iec_tree_main$' >/dev/null || iec_err "tree: entry iec_tree_main is not exported"
iec_log "done: $OUT_DIR/libtreecmd.so"
