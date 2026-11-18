#!/usr/bin/env bash
# 扫描随包归档里的可执行二进制：只允许本工程为鸿蒙编译的那几个 .node；
# 并检查 ELF 加固标志（RELRO / BIND_NOW / NX / stack canary）。
#
# 路径可配置（不再写死 /mnt/d）：
#   ROOT   仓库根目录
#   T      official-engine.tar.gz
#   N      npm.tar.gz
#   HAP    可选：HAP 路径（存在时顺便审计 entry/libs）
#   READELF llvm-readelf/readelf
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="${T:-$ROOT/entry/src/main/resources/rawfile/tools/official-engine.tar.gz}"
N="${N:-$ROOT/entry/src/main/resources/rawfile/tools/npm.tar.gz}"
HAP="${HAP:-$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap}"
READELF="${READELF:-$(command -v llvm-readelf 2>/dev/null || command -v readelf 2>/dev/null || true)}"
WA="$(mktemp -d "${TMPDIR:-/tmp}/pocket-harness-bin-audit.XXXXXX")"
trap 'rm -rf "$WA"' EXIT

[ -f "$T" ] || { echo "找不到引擎归档：$T" >&2; exit 1; }

EXPECTED='./node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/gnu/system.node
./node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/musl/system.node
./node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-arm64-gnu/require_builtin.node
./node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-arm64-musl/require_builtin.node
./node_modules/node-pty/build/Release/pty.node'

echo '=== 1. 引擎归档里的二进制 ==='
ACTUAL=$(tar -tzf "$T" | grep -E '\.(node|so|dll|exe|dylib|a|lib|wasm)$' | sort)
echo "$ACTUAL" | sed 's/^/  /'
echo
echo '=== 2. 与预期比对 ==='
if [ "$(printf '%s\n' "$ACTUAL" | sort)" = "$(printf '%s\n' "$EXPECTED" | sort)" ]; then
  echo '  ok：只有本工程编译的 5 个 .node'
else
  echo '  差异：'
  diff <(printf '%s\n' "$EXPECTED" | sort) <(printf '%s\n' "$ACTUAL" | sort) | sed 's/^/    /'
fi

echo
echo '=== 3. npm 归档里的二进制 ==='
if [ -f "$N" ]; then
  BIN=$(tar -tzf "$N" | grep -E '\.(node|so|dll|exe|dylib)$' || true)
  [ -z "$BIN" ] && echo '  （无）' || echo "$BIN" | sed 's/^/  /'
else
  echo '  MISS npm.tar.gz（构建产物）'
fi

echo
echo '=== 4. 引擎归档内的 ELF 加固 ==='
if [ -n "$READELF" ]; then
  tar -xzf "$T" -C "$WA" >/dev/null 2>&1 || true
  found=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    found=1
    f="$WA/$rel"
    [ -f "$f" ] || continue
    relro=no; now=no; nx=no
    "$READELF" -l -W "$f" 2>/dev/null | grep -q 'GNU_RELRO' && relro=yes
    "$READELF" -d -W "$f" 2>/dev/null | grep -qE 'BIND_NOW|FLAGS.*NOW' && now=yes
    if ! "$READELF" -l -W "$f" 2>/dev/null | awk '/GNU_STACK/{print $7}' | grep -q 'E'; then
      nx=yes
    fi
    canary=no
    "$READELF" -s -W "$f" 2>/dev/null | grep -q '__stack_chk_fail' && canary=yes
    printf '  %-28s RELRO=%s NOW=%s NX=%s CANARY=%s\n' "$(basename "$rel")" "$relro" "$now" "$nx" "$canary"
  done <<< "$ACTUAL"
  [ "$found" -eq 1 ] || echo '  （无 ELF）'
else
  echo '  跳过：找不到 llvm-readelf/readelf'
fi

echo
echo '=== 5. HAP 内原生库的 ELF 加固（有 HAP 时）==='
if [ -f "$HAP" ] && [ -n "$READELF" ]; then
  unzip -q "$HAP" 'libs/*' -d "$WA/hap" 2>/dev/null || true
  for f in "$WA/hap"/libs/*/*.so*; do
    [ -f "$f" ] || continue
    relro=no; now=no; nx=no
    "$READELF" -l -W "$f" 2>/dev/null | grep -q 'GNU_RELRO' && relro=yes
    "$READELF" -d -W "$f" 2>/dev/null | grep -qE 'BIND_NOW|FLAGS.*NOW' && now=yes
    if ! "$READELF" -l -W "$f" 2>/dev/null | awk '/GNU_STACK/{print $7}' | grep -q 'E'; then
      nx=yes
    fi
    canary=no
    "$READELF" -s -W "$f" 2>/dev/null | grep -q '__stack_chk_fail' && canary=yes
    printf '  %-24s RELRO=%s NOW=%s NX=%s CANARY=%s\n' "$(basename "$f")" "$relro" "$now" "$nx" "$canary"
  done
else
  echo "  跳过：$([ -f "$HAP" ] && echo '找不到 readelf' || echo "找不到 HAP：$HAP")"
fi
