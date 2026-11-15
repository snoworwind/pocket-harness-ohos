#!/usr/bin/env bash
# 用宿主 Node 验证随包引擎归档能否解析 web profile（官方 Web GUI 的插件表）。
# 只跑 --dump-config：不 bind 端口、不启动 Agent、不加载 OHOS 的 .node 插件。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
W=/var/tmp/engine-web-check
rm -rf "$W"; mkdir -p "$W/engine" "$W/home"
tar -C "$W/engine" -xzf "$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
export DSH_HOME="$W/home"
export PATH="$R/host-node/bin:$PATH"
NODE="$R/host-node/bin/node"
echo "node: $($NODE -v)"
cd "$W/engine" || exit 1
"$NODE" node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config > "$W/dump.yml" 2> "$W/dump.err"
echo "exit=$?"
echo "plugin entries: $(grep -c "name: '" "$W/dump.yml" 2>/dev/null || echo 0)"
echo "dump lines: $(wc -l < "$W/dump.yml")"
echo '=== stderr（截断）==='
head -15 "$W/dump.err"
echo '=== 前 10 行 ==='
head -10 "$W/dump.yml"
