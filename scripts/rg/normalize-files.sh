#!/usr/bin/env bash
set -euo pipefail
P=/mnt/d/forGithub/deepseek-harmony
for f in "$P/.gitignore"; do
  if grep -q $'\r' "$f"; then
    sed -i 's/\r$//' "$f"
    echo "normalized: $f"
  else
    echo "ok: $f"
  fi
done
echo '--- .gitignore ---'
cat "$P/.gitignore"
echo '--- CR check on edited scripts ---'
for f in "$P/scripts/pack-native.sh" "$P/scripts/audit-sources.sh" "$P/docs/VALIDATION.md" "$P/README.md"; do
  printf '%s: ' "$(basename "$f")"
  grep -c $'\r' "$f" || true
done
