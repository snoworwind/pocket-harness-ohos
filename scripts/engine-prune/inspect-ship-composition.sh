#!/usr/bin/env bash
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
LIST="$P/scripts/engine-ship-files.txt"
NM="$R/official-engine/node_modules"
echo '=== 顶层包数量 ==='
awk -F/ '{ if ($0 ~ /^@/) print $1"/"$2; else print $1 }' "$LIST" | sort -u | wc -l
echo '=== 体积最大的 15 个包 ==='
awk -F/ '{ if ($0 ~ /^@/) print $1"/"$2; else print $1 }' "$LIST" | sort -u | while read -r pkg; do
  size=$(find "$NM/$pkg" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
  echo "$size $pkg"
done | sort -rn | head -15 | awk '{printf "  %6.1f MB  %s\n", $1/1048576, $2}'
echo '=== 清单里疑似预编译二进制 ==='
while read -r f; do
  case "$f" in
    */bin/*|*.wasm|*.a|*.lib) file -b "$NM/$f" 2>/dev/null | grep -qE 'ELF|executable|archive' && echo "  $f";;
  esac
done < "$LIST" | head -20
