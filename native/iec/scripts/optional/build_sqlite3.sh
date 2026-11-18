#!/bin/bash
# build_sqlite3.sh — SQLite 3 CLI as an IEC command object.
#
# The amalgamation is compiled directly (no configure): one sqlite3.c plus the
# shell front-end.  The static library and headers are also installed into the
# IEC dependency prefix so a later CPython configure can enable _sqlite3.
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libsqlite3cmd.so
#   build/deps/usr/lib/<target>/libsqlite3.a
#   build/deps/usr/include/sqlite3.h
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

SQLITE_VER="${SQLITE_VER:-3500400}"
TAR="$IEC_THIRDPARTY/sqlite-autoconf-$SQLITE_VER.tar.gz"
# sqlite.org 只发布 SHA3-256，不提供 SHA-256；未固定时 CI 失败，普通构建告警。
SHA256="$(iec_sha_or IEC_SQLITE_SHA256 a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18)"
SRC="$IEC_THIRDPARTY/sqlite-autoconf-$SQLITE_VER"
WORK="$IEC_ROOT/build/sqlite3"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK" "$OUT_DIR" "$IEC_THIRDPARTY"
iec_fetch_verified "https://sqlite.org/2025/sqlite-autoconf-$SQLITE_VER.tar.gz" \
	"$TAR" "$SHA256" "sqlite $SQLITE_VER"
if [ ! -f "$SRC/sqlite3.c" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TAR" -C "$SRC" --strip-components=1
fi

SQLITE_FLAGS=(-O2 -fPIC -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5
	-DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_COLUMN_METADATA
	-DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_MATH_FUNCTIONS
	-DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_USE_URI=1)

$CC_TARGET "${SQLITE_FLAGS[@]}" -c "$SRC/sqlite3.c" -o "$WORK/sqlite3.o"
$CC_TARGET -O2 -fPIC -Dmain=iec_sqlite3_main -DSQLITE_SHELL_IS_UTF8 -DSQLITE_OMIT_LOAD_EXTENSION \
	-c "$SRC/shell.c" -o "$WORK/sqlite3_shell.o"

# Install the library/header for CPython's _sqlite3 module (optional for this
# build, but it makes the Python runtime much more useful).
mkdir -p "$IEC_DEPS_LIB" "$IEC_DEPS_INC"
"$CLANG_DIR/llvm-ar" rcs "$IEC_DEPS_LIB/libsqlite3.a" "$WORK/sqlite3.o"
cp -f "$SRC/sqlite3.h" "$SRC/sqlite3ext.h" "$IEC_DEPS_INC/"

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/libsqlite3cmd.so" \
	"$WORK/sqlite3_shell.o" "$WORK/sqlite3.o" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libsqlite3cmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libsqlite3cmd.so" \
	| grep ' iec_sqlite3_main$' >/dev/null || iec_err "sqlite3: entry iec_sqlite3_main is not exported"
iec_log "done: $OUT_DIR/libsqlite3cmd.so"
