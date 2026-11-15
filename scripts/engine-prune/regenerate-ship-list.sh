#!/bin/bash
# 用 sdk + web 两份 profile dump 重新生成引擎文件清单（修复 doc/ 目录误删）。
set -eu
NODE=/var/tmp/deepseek-harmony-native/host-node/bin/node
SCRIPT=/mnt/d/forGithub/deepseek-harmony/scripts/engine-prune/ship-from-dump.mjs
OUT=/mnt/d/forGithub/deepseek-harmony/scripts/engine-ship-files.txt
NM=/var/tmp/deepseek-harmony-native/official-engine/node_modules
cat /var/tmp/engine-dump-full/dump.yml /var/tmp/engine-web-check/dump.yml > /var/tmp/dump-all.yml
"$NODE" "$SCRIPT" /var/tmp/dump-all.yml "$NM" "$OUT"
echo "files: $(wc -l < "$OUT")"
echo "yaml doc: $(grep -c 'yaml/dist/doc/' "$OUT")"
echo "packages: $(awk -F/ '{ if ($0 ~ /^@/) print $1"/"$2; else print $1 }' "$OUT" | sort -u | wc -l)"
