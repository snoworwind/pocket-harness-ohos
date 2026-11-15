#!/usr/bin/env bash
set -euo pipefail
R=/var/tmp/deepseek-harmony-native
SRC=$R/sdk/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
DST=$R/llvm22/usr/lib/clang/22/lib/aarch64-linux-ohos
ls "$SRC" | head -8
mkdir -p "$(dirname "$DST")"
ln -sfn "$SRC" "$DST"
ls -la "$DST" | head -3
echo CRT_LINKED
