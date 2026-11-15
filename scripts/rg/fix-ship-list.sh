#!/usr/bin/env bash
set -euo pipefail
NEW=/mnt/d/forGithub/deepseek-harmony/scripts/engine-ship-files.txt
OLD=/mnt/c/Users/zouha/Documents/Codex/2026-11-15/ca/outputs/deepseek-harmony/scripts/engine-ship-files.txt
cp -f "$OLD" "$NEW"
grep -v '^@vscode/ripgrep' "$NEW" > "$NEW.tmp"
mv "$NEW.tmp" "$NEW"
echo "lines: $(wc -l < "$NEW")"
echo "CR count: $(grep -c $'\r' "$NEW" || true)"
echo "vscode refs: $(grep -c '@vscode/ripgrep' "$NEW" || true)"
head -2 "$NEW" | cat -A | head -2
