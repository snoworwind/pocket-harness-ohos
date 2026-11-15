#!/usr/bin/env bash
# 扫描随包归档里的可执行二进制：只允许本工程为鸿蒙编译的那几个 .node。
set -u
P=/mnt/d/forGithub/deepseek-harmony
T="$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
N="$P/native/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz"

EXPECTED='./node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/gnu/system.node
./node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/musl/system.node
./node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-arm64-gnu/require_builtin.node
./node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-arm64-musl/require_builtin.node
./node_modules/node-pty/build/Release/pty.node'

echo '=== 引擎归档里的二进制 ==='
ACTUAL=$(tar -tzf "$T" | grep -E '\.(node|so|dll|exe|dylib|a|lib|wasm)$' | sort)
echo "$ACTUAL" | sed 's/^/  /'
echo
echo '=== 与预期比对 ==='
if [ "$(printf '%s\n' "$ACTUAL" | sort)" = "$(printf '%s\n' "$EXPECTED" | sort)" ]; then
  echo '  ok：只有本工程编译的 5 个 .node'
else
  echo '  差异：'
  diff <(printf '%s\n' "$EXPECTED" | sort) <(printf '%s\n' "$ACTUAL" | sort) | sed 's/^/    /'
fi
echo
echo '=== npm 归档里的二进制 ==='
BIN=$(tar -tzf "$N" | grep -E '\.(node|so|dll|exe|dylib)$')
[ -z "$BIN" ] && echo '  （无）' || echo "$BIN" | sed 's/^/  /'
