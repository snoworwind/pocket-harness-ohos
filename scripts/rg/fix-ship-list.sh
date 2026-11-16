#!/usr/bin/env bash
# 把 engine-ship-files.txt 从旧位置同步到本仓库，并去掉 @vscode/ripgrep 行。
# 用法：OLD=/path/to/old/engine-ship-files.txt bash scripts/rg/fix-ship-list.sh
set -euo pipefail
NEW=${NEW:-"$(cd "$(dirname "$0")/../.." && pwd)/scripts/engine-ship-files.txt"}
OLD=${OLD:?请设置 OLD 指向旧的 engine-ship-files.txt}
cp -f "$OLD" "$NEW"
grep -v '^@vscode/ripgrep' "$NEW" > "$NEW.tmp"
mv "$NEW.tmp" "$NEW"
echo "lines: $(wc -l < "$NEW")"
echo "CR count: $(grep -c $'\r' "$NEW" || true)"
echo "vscode refs: $(grep -c '@vscode/ripgrep' "$NEW" || true)"
head -2 "$NEW" | cat -A | head -2
