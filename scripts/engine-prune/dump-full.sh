#!/usr/bin/env bash
# 用完整引擎树（含 dsh-base）导出 sdk profile 的插件表，作为打包清单的输入。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
W=/var/tmp/engine-dump-full
rm -rf "$W"; mkdir -p "$W/home"
export DSH_HOME="$W/home"
export PATH="$R/host-node/bin:$PATH"
NODE="$R/host-node/bin/node"
cd "$R/official-engine" || exit 1
"$NODE" node_modules/@deepseek-ai/dsh/lib/bin.js --profile sdk --dump-config > "$W/dump.yml" 2> "$W/dump.err"
echo "exit=$?"
echo "lines: $(wc -l < "$W/dump.yml")"
echo "plugin entries: $(grep -c "name: '" "$W/dump.yml")"
echo "unique packages: $(grep "name: '" "$W/dump.yml" | sed "s/.*name: '//; s/'.*//" | sort -u | wc -l)"
echo '=== stderr (head) ==='
head -8 "$W/dump.err"
