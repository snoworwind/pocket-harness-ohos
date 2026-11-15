#!/usr/bin/env bash
set -euo pipefail
R=/var/tmp/deepseek-harmony-native
LIB=$R/sdk/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
# 上游 clang 驱动会找 GCC 风格的 crtbeginS/crtendS；OHOS 工具链只带 compiler-rt 版本。
ln -sfn clang_rt.crtbegin.o "$LIB/crtbeginS.o"
ln -sfn clang_rt.crtend.o "$LIB/crtendS.o"
ls -la "$LIB/crtbeginS.o" "$LIB/crtendS.o"
echo CRT_ALIASES_READY
