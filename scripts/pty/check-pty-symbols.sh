#!/usr/bin/env bash
set -u
R=/var/tmp/deepseek-harmony-native
SYS=$R/sdk/native/sysroot/usr/lib/aarch64-linux-ohos
NM=$R/sdk/native/llvm/bin/llvm-nm
echo '=== libc.so 里是否有 forkpty/openpty/login_tty ==='
for sym in forkpty openpty login_tty getpt grantpt unlockpt ptsname; do
  found=$($NM -D --defined-only "$SYS/libc.so" 2>/dev/null | grep -c " T $sym\$")
  echo "  $sym: $found"
done
echo '=== libutil.a 内容 ==='
$NM --defined-only "$SYS/libutil.a" 2>/dev/null | grep -E ' T (forkpty|openpty|login_tty)$' | head
$R/sdk/native/llvm/bin/llvm-ar t "$SYS/libutil.a" 2>/dev/null | head
