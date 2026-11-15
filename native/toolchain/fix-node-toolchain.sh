#!/usr/bin/env bash
set -euo pipefail
ROOT=/var/tmp/deepseek-harmony-native
mkdir -p "$ROOT/compiler/bin"
RESOURCE="$ROOT/llvm22/usr/lib/clang/22"
cat > "$ROOT/compiler/bin/clang" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$ROOT/llvm22/usr/lib/x86_64-linux-gnu"
exec "$ROOT/llvm22/usr/bin/clang-22" -resource-dir="$RESOURCE" -L"$ROOT/sdk/native/llvm/lib/aarch64-linux-ohos" "\$@"
EOF
cat > "$ROOT/compiler/bin/clang++" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$ROOT/llvm22/usr/lib/x86_64-linux-gnu"
exec "$ROOT/llvm22/usr/bin/clang++-22" -resource-dir="$RESOURCE" -stdlib=libc++ -isystem "$ROOT/ndk-cxx/include/c++/v1" -L"$ROOT/ndk-cxx/lib/aarch64-linux-ohos" -L"$ROOT/sdk/native/llvm/lib/aarch64-linux-ohos" "\$@"
EOF
chmod +x "$ROOT/compiler/bin/clang" "$ROOT/compiler/bin/clang++"
echo WRAPPER_UPDATED
"$ROOT/compiler/bin/clang" --target=aarch64-linux-ohos --sysroot="$ROOT/sdk/native/sysroot" -x c -c -o /tmp/probe-neon.o - <<<'#include <arm_neon.h>
int probe(void){ return (int)vaddvq_u8(vdupq_n_u8(1)); }' && echo NEON_PROBE_OK
