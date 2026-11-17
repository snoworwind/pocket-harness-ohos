#!/bin/bash
# build_opensslcmd.sh — OpenSSL command-line tool as an IEC command object.
#
# Reuses the static OpenSSL tree built for Git (build_openssl.sh).  The app
# objects are already -fPIC; only main() needs renaming and the whole set is
# linked with the IEC shims.
#
# Output: platform/ohos/har/libs/arm64-v8a/libopensslcmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

SRC="$IEC_THIRDPARTY/openssl"
# OpenSSL 3 is configured out of tree (build/openssl-build), so the command
# objects live next to the build, not next to the source. Older/in-source trees
# still work via the fallback below.
OSSL_BUILD="${IEC_OPENSSL_BUILD:-$IEC_ROOT/build/openssl-build}"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
WORK="$IEC_ROOT/build/opensslcmd"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

if [ ! -f "$OSSL_BUILD/apps/openssl-bin-openssl.o" ] && [ ! -f "$SRC/apps/openssl-bin-openssl.o" ]; then
	"$IEC_ROOT/scripts/optional/build_openssl.sh"
fi
APPS_DIR="$OSSL_BUILD/apps"
[ -f "$APPS_DIR/openssl-bin-openssl.o" ] || APPS_DIR="$SRC/apps"
[ -f "$APPS_DIR/openssl-bin-openssl.o" ] || iec_err "OpenSSL apps objects are missing (looked in $OSSL_BUILD/apps and $SRC/apps; delete $IEC_OPENSSL_DIR and rebuild)"
SSL_LIB_DIR="$IEC_OPENSSL_DIR/lib"
[ -f "$SSL_LIB_DIR/libssl.a" ] || SSL_LIB_DIR="$SRC"
[ -f "$SSL_LIB_DIR/libssl.a" ] || iec_err "OpenSSL static libraries are missing (looked in $IEC_OPENSSL_DIR/lib and $SRC)"
mkdir -p "$WORK" "$OUT_DIR"

"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_openssl_main \
	"$APPS_DIR/openssl-bin-openssl.o" "$WORK/openssl_main.o"

declare -a OBJS=()
while IFS= read -r obj; do
	OBJS+=("$obj")
done < <(find "$APPS_DIR" -maxdepth 1 -name 'openssl-bin-*.o' ! -name 'openssl-bin-openssl.o' | sort)
while IFS= read -r obj; do
	OBJS+=("$obj")
done < <(find "$APPS_DIR/lib" -maxdepth 1 -name '*.o' | sort)

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

$CC_TARGET -shared -o "$OUT_DIR/libopensslcmd.so" "$WORK/openssl_main.o" "${OBJS[@]}" \
	"$SSL_LIB_DIR/libssl.a" "$SSL_LIB_DIR/libcrypto.a" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libopensslcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libopensslcmd.so" \
	| grep ' iec_openssl_main$' >/dev/null || iec_err "openssl: entry iec_openssl_main is not exported"
iec_log "done: $OUT_DIR/libopensslcmd.so"
