#!/usr/bin/env bash
set -u
P=/mnt/d/forGithub/deepseek-harmony
T="$P/entry/src/main/resources/rawfile/tools/official-engine.tar.gz"
echo "entries: $(tar -tzf "$T" | wc -l)"
echo '=== addons in engine archive ==='
tar -tzf "$T" | grep -E 'require_builtin\.node|system\.node|node-addon-system-linux-arm64/package\.json' || echo 'NO_ADDONS'
echo '=== engine entry point ==='
tar -tzf "$T" | grep -c 'node_modules/@deepseek-ai/dsh/lib/bin.js'
echo '=== manifest ==='
cat "$P/entry/src/main/resources/rawfile/tools/runtime-manifest.json" | head -6
