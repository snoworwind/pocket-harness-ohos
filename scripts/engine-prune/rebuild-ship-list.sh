#!/usr/bin/env bash
# 用完整 dump 重新生成 ship 清单，并打出一个候选引擎归档做验证。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
DUMP=/var/tmp/engine-dump-full/dump.yml
OUT="$P/scripts/engine-ship-files.txt"
export PATH="$R/host-node/bin:$PATH"

"$R/host-node/bin/node" "$P/scripts/engine-prune/ship-from-dump.mjs" "$DUMP" "$R/official-engine/node_modules" "$OUT"
echo "list lines: $(wc -l < "$OUT")"
echo '=== dsh-base 是否包含 ==='
grep -c '^@deepseek-ai/dsh-base/' "$OUT" || true
echo '=== 外部平台预编译是否排除 ==='
grep -c 'prebuilds/' "$OUT" || true
