#!/usr/bin/env bash
# 扫描清单内每个文件，找出真正的 ELF/PE 二进制（脚本不算）。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
LIST="$P/scripts/engine-ship-files.txt"
NM="$R/official-engine/node_modules"
found=0
while IFS= read -r f; do
  path="$NM/$f"
  [ -f "$path" ] || continue
  magic=$(head -c 4 "$path" | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    7f454c46) echo "ELF  $f"; found=$((found+1));;
    4d5a*) echo "PE   $f"; found=$((found+1));;
  esac
done < "$LIST"
echo "binary files: $found"
