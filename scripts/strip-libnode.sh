#!/bin/bash
# 给 libnode.so 做 strip 并核对 IEC 入口与 wrap 符号还在（HAP 体积主要就它）。
set -eu
L=/var/tmp/deepseek-harmony-native/iec/platform/ohos/har/libs/arm64-v8a/libnode.so
STRIP=/var/tmp/deepseek-harmony-native/sdk/native/llvm/bin/llvm-strip
ls -l "$L"
"$STRIP" --strip-unneeded "$L"
echo "after strip:"
ls -l "$L"
echo "iec_* entry and __wrap_ exports: $(nm -D --defined-only "$L" | grep -cE 'iec_(node|npm|npx)_main|__wrap_')"
echo "undefined std::__1: $(readelf --dyn-syms -W "$L" | grep -c 'UND.*_ZNSt3__1')"
echo "undefined std::__n1: $(readelf --dyn-syms -W "$L" | grep -c 'UND.*_ZNSt4__n1')"
