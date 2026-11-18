#!/usr/bin/env bash
# 审计 HAP 里随包分发的二进制与归档，确认来源都是本机构建或官方 SDK。
#
# 路径全部可配置（不再写死 /mnt/d 或 /var/tmp）：
#   ROOT       仓库根目录（默认脚本上一级）
#   HAP        HAP 路径（默认 entry/build/.../entry-default-unsigned.hap）
#   NATIVE_ROOT 原生构建树（默认 $ROOT 的同级 deepseek-harmony-native，可覆盖）
#   WORKDIR    解包临时目录（默认 mktemp -d）
#   READELF    llvm-readelf/readelf（默认从 PATH 找）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HAP="${HAP:-$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap}"
NATIVE_ROOT="${NATIVE_ROOT:-$(cd "$ROOT/.." && pwd)/deepseek-harmony-native}"
READELF="${READELF:-$(command -v llvm-readelf 2>/dev/null || command -v readelf 2>/dev/null || true)}"
WA="${WORKDIR:-}"
OWN_WA=0
if [ -z "$WA" ]; then
  WA="$(mktemp -d "${TMPDIR:-/tmp}/pocket-harness-audit.XXXXXX")"
  OWN_WA=1
fi
cleanup() { [ "$OWN_WA" -eq 1 ] && rm -rf "$WA"; }
trap cleanup EXIT

[ -f "$HAP" ] || { echo "找不到 HAP：$HAP" >&2; exit 1; }
unzip -q "$HAP" -d "$WA" || { echo "HAP 解包失败" >&2; exit 1; }

echo '=== 1. HAP 内的二进制 ==='
find "$WA/libs" -name '*.so*' -printf '%f %s\n' 2>/dev/null | sort

echo
echo '=== 2. 预期集合核对 ==='
EXPECTED='libnode.so libpython.so libbash.so libtoybox.so libbsdtar.so libbsdcpio.so libbsdunzip.so libzipcmd.so librg.so libarchive.so.13 libgit.so libgit-remote-http.so libgitlfscmd.so libcurlcmd.so libjqcmd.so libbccmd.so libnc.so libhexdump.so libdiff.so libdropbear.so libsftpcmd.so liblesscmd.so libvimcmd.so libghcmd.so libopensslcmd.so libtreecmd.so libsqlite3cmd.so librsynccmd.so libxzcmd.so libzstdcmd.so libiec_server.so libncploader.so libdsh_terminal.so libc++_shared.so'
for name in $EXPECTED; do
  if [ -f "$WA/libs/arm64-v8a/$name" ]; then echo "ok   $name"; else echo "MISS $name"; fi
done
ACTUAL=$(find "$WA/libs/arm64-v8a" -name '*.so*' -printf '%f\n' | sort)
WANT=$(printf '%s\n' $EXPECTED | sort)
EXTRA=$(comm -13 <(echo "$WANT") <(echo "$ACTUAL"))
MISSING=$(comm -23 <(echo "$WANT") <(echo "$ACTUAL"))
[ -z "$MISSING" ] || echo "缺少：$MISSING"
[ -z "$EXTRA" ] && echo '无额外 .so' || echo "额外 .so：$EXTRA"

echo
echo '=== 3. 引擎归档内的原生插件 ==='
tar -tzf "$WA/resources/rawfile/tools/official-engine.tar.gz" | grep -E '\.node$|node-addon-system-linux-arm64/package.json' | sed 's/^/  /'

echo
echo '=== 4. npm 归档比对（应为 Node 源码构建产物）==='
REBUILT="$NATIVE_ROOT/iec/platform/ohos/har/src/main/resources/rawfile/tools/npm.tar.gz"
if [ -f "$REBUILT" ]; then
  sha256sum "$WA/resources/rawfile/tools/npm.tar.gz" "$REBUILT" 2>/dev/null | awk '{print "  "$0}'
  if cmp -s "$WA/resources/rawfile/tools/npm.tar.gz" "$REBUILT"; then
    echo '  npm 与本次构建一致'
  else
    echo '  npm 与本次构建不一致'
  fi
else
  echo "  跳过：找不到本次构建的 npm.tar.gz（NATIVE_ROOT=$NATIVE_ROOT）"
fi

echo
echo '=== 5. 引擎完整性清单 ==='
SUMS="$WA/resources/rawfile/tools/official-engine.sha256"
if [ -f "$SUMS" ]; then
  ( cd "$WA/resources/rawfile/tools" && sha256sum -c official-engine.sha256 ) | sed 's/^/  /'
else
  echo '  MISS official-engine.sha256（pack-native.sh 应生成）'
fi

echo
echo '=== 6. ELF 架构抽查 ==='
if [ -n "$READELF" ]; then
  for so in libnode.so libbash.so libtoybox.so librg.so; do
    printf '  %-14s ' "$so"
    "$READELF" -h "$WA/libs/arm64-v8a/$so" 2>/dev/null | awk '/Machine:/{print $2, $3}'
  done
else
  echo '  跳过：找不到 llvm-readelf/readelf'
fi

echo
echo '=== 7. 引擎入口与 Manifest ==='
tar -tzf "$WA/resources/rawfile/tools/official-engine.tar.gz" | grep -c 'node_modules/@deepseek-ai/dsh/lib/bin.js' | sed 's/^/  dsh bin.js: /'
grep -c '"name"' "$WA/resources/rawfile/tools/runtime-manifest.json" | sed 's/^/  manifest commands: /'

echo
echo '=== 8. libc++ ABI（必须只引用 std::__n1）==='
if [ -n "$READELF" ]; then
  for so in libnode.so libarchive.so.13; do
    old=$("$READELF" --dyn-syms -W "$WA/libs/arm64-v8a/$so" 2>/dev/null | grep -c 'UND.*_ZNSt3__1' || true)
    new=$("$READELF" --dyn-syms -W "$WA/libs/arm64-v8a/$so" 2>/dev/null | grep -c 'UND.*_ZNSt4__n1' || true)
    printf '  %-18s std::__1=%s std::__n1=%s\n' "$so" "${old:-0}" "${new:-0}"
  done
else
  echo '  跳过：找不到 llvm-readelf/readelf'
fi

echo
echo '=== 9. 二进制加固（RELRO/NOW/NX/stack canary）==='
if [ -n "$READELF" ]; then
  for so in $EXPECTED; do
    f="$WA/libs/arm64-v8a/$so"
    [ -f "$f" ] || continue
    relro=no; now=no
    "$READELF" -l -W "$f" 2>/dev/null | grep -q 'GNU_RELRO' && relro=yes
    "$READELF" -d -W "$f" 2>/dev/null | grep -qE 'BIND_NOW|FLAGS.*NOW' && now=yes
    nx=no
    if "$READELF" -l -W "$f" 2>/dev/null | awk '/GNU_STACK/{print $7}' | grep -q 'E'; then
      nx=no
    else
      nx=yes
    fi
    canary=no
    "$READELF" -s -W "$f" 2>/dev/null | grep -q '__stack_chk_fail' && canary=yes
    printf '  %-20s RELRO=%s NOW=%s NX=%s CANARY=%s\n' "$so" "$relro" "$now" "$nx" "$canary"
  done
else
  echo '  跳过：找不到 llvm-readelf/readelf'
fi
