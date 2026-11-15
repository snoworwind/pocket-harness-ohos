#!/bin/bash
# 列出 libnode.so 需要、但随包 libc++_shared.so / libc.so 都没有的符号。
# 这些就是真机 dlopen 时 "symbol not found" 的来源。
set -u
L=/var/tmp/deepseek-harmony-native/iec/platform/ohos/har/libs/arm64-v8a/libnode.so
CXX=/var/tmp/deepseek-harmony-native/ndk-cxx/lib/aarch64-linux-ohos/libc++_shared.so
LIBC=/var/tmp/deepseek-harmony-native/sdk/native/sysroot/usr/lib/aarch64-linux-ohos/libc.so
W=/var/tmp/symdiff
mkdir -p "$W"

readelf --dyn-syms -W "$L" | awk '$7 == "UND" { print $8 }' | sort -u > "$W/undef.txt"
{ nm -D --defined-only "$CXX" 2>/dev/null | awk '{ print $3 }'; nm -D --defined-only "$LIBC" 2>/dev/null | awk '{ print $3 }'; } | sort -u > "$W/defined.txt"
comm -23 "$W/undef.txt" "$W/defined.txt" > "$W/missing.txt"

echo "undefined in libnode: $(wc -l < "$W/undef.txt")"
echo "missing: $(wc -l < "$W/missing.txt")"
grep '_ZNSt\|_ZSt\|_ZNKS' "$W/missing.txt" | sed 's/^/  /' | head -60
echo '--- 非 C++ 的缺失（应为 0）---'
grep -v '_ZNSt\|_ZSt\|_ZNKS' "$W/missing.txt" | head -20
