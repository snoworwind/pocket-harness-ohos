#!/usr/bin/env bash
# 将 GNU Bash 编译为 IEC 可装载的鸿蒙原生命令对象。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IEC_ROOT=${IEC_ROOT:-$HERE/iec}
: "${OHOS_SDK:?Set OHOS_SDK to the Linux OpenHarmony SDK root}"
CLANG="$OHOS_SDK/native/llvm/bin/clang"
SYSROOT="$OHOS_SDK/native/sysroot"
BUILD_ROOT=${BUILD_ROOT:-$IEC_ROOT/build/bash}
OUTDIR=${OUTDIR:-$IEC_ROOT/platform/ohos/har/libs/arm64-v8a}
JOBS=${JOBS:-6}
TARGET=${TARGET:-aarch64-linux-ohos}
mkdir -p "$BUILD_ROOT" "$OUTDIR"
cd "$BUILD_ROOT"
if [ ! -f bash-5.3.tar.gz ]; then curl -fL --retry 3 https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz -o bash-5.3.tar.gz; fi
sha256sum bash-5.3.tar.gz > source.sha256
if [ ! -f bash-5.3/configure ]; then tar -xzf bash-5.3.tar.gz; fi
cat > cc <<EOF
#!/bin/sh
exec "$CLANG" --target=$TARGET --sysroot="$SYSROOT" -fuse-ld=lld "\$@"
EOF
chmod +x cc
export CC="$BUILD_ROOT/cc" CC_FOR_BUILD=gcc CFLAGS_FOR_BUILD=-O2
cd bash-5.3
if [ ! -f Makefile ]; then
  CFLAGS='-O2 -fPIC' ./configure --host="$TARGET" --build=x86_64-pc-linux-gnu \
    --without-bash-malloc --disable-nls --disable-rpath > "$BUILD_ROOT/configure.log" 2>&1
fi
make -j"$JOBS" CC_FOR_BUILD='gcc -std=gnu17' > "$BUILD_ROOT/make.log" 2>&1
SHIM="$BUILD_ROOT/shims"
mkdir -p "$SHIM"
for unit in tty/shim fs/shim exec/shim common/rpc common/sock_client compat/exit_wrap; do
  object=${unit//\//_}
  "$CC" -O2 -fPIC -D_GNU_SOURCE -DINT_WARP -DIEC_SHIM_MERGED_OPEN -I"$IEC_ROOT" -I"$IEC_ROOT/common" \
    -c "$IEC_ROOT/$unit.c" -o "$SHIM/$object.o"
done
# 只重编入口对象，构建机工具保留其真正的 main。
rm -f shell.o bash
make shell.o CC_FOR_BUILD='gcc -std=gnu17' CFLAGS='-O2 -fPIC -Dmain=iec_bash_main' >> "$BUILD_ROOT/make.log" 2>&1
WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat chmod fchmod fchmodat
  open openat unlink unlinkat rename renameat access faccessat realpath link linkat
  opendir readdir scandir fopen freopen utimensat syscall close dup dup2 dup3 fcntl
  ioctl isatty ttyname ttyname_r tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt
  unlockpt ptsname openpty login_tty forkpty execve execv execvp execvpe execl execlp execle
  popen pclose system exit)
LINK_FLAGS="-shared -Wl,-soname,libbash.so"
for name in "${WRAPS[@]}"; do LINK_FLAGS+=" -Wl,--wrap=$name"; done
for object in "$SHIM"/*.o; do LINK_FLAGS+=" $object"; done
make bash CC_FOR_BUILD='gcc -std=gnu17' LDFLAGS="$LINK_FLAGS" >> "$BUILD_ROOT/make.log" 2>&1
cp bash "$OUTDIR/libbash.so"
"$OHOS_SDK/native/llvm/bin/llvm-nm" -D "$OUTDIR/libbash.so" | grep ' iec_bash_main$'
"$OHOS_SDK/native/llvm/bin/llvm-readelf" -d "$OUTDIR/libbash.so" > "$BUILD_ROOT/dynamic.txt"
echo "BASH_NATIVE_READY $OUTDIR/libbash.so"
