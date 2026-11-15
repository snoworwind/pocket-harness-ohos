#!/usr/bin/env bash
set -u
P=/mnt/d/forGithub/deepseek-harmony
echo "node-pty entries: $(grep -c '^node-pty/' "$P/scripts/engine-ship-files.txt" || true)"
grep -E '^node-pty/(lib|package)' "$P/scripts/engine-ship-files.txt" | head -5
echo "预编译二进制是否排除: $(grep -c 'node-pty/prebuilds' "$P/scripts/engine-ship-files.txt" || true)"
