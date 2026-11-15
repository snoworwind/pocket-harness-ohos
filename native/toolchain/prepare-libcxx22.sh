#!/usr/bin/env bash
set -euo pipefail
ROOT=/var/tmp/deepseek-harmony-native
mkdir -p "$ROOT/llvm22-debs" "$ROOT/llvm22" "$ROOT/logs"
cd "$ROOT/llvm22-debs"
# libc++ 22 的头文件：NDK 自带的 libc++ 15 没有 std::views / ranges 算法，
# Node 24 的 V8 与 src 都依赖它们。
apt-get download libc++-22-dev libc++abi-22-dev > "$ROOT/logs/libcxx22-download.log" 2>&1 || {
  cat "$ROOT/logs/libcxx22-download.log" >&2; exit 1; }
for package in libc++-22-dev*.deb libc++abi-22-dev*.deb; do dpkg-deb -x "$package" "$ROOT/llvm22"; done
ls "$ROOT/llvm22/usr/include/c++/v1" | head -3
echo LIBCXX22_READY
