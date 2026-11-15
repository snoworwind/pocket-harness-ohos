#!/usr/bin/env bash
# 迭代补齐：反复验证裁剪后的引擎树，直到 sdk profile 能完整解析。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
DUMP=/var/tmp/engine-dump-full/dump.yml
LIST="$P/scripts/engine-ship-files.txt"
EXTRAS=/var/tmp/engine-ship-extras.txt
W=/var/tmp/engine-ship-verify
export PATH="$R/host-node/bin:$PATH"
NODE="$R/host-node/bin/node"

# 把 '@scope/name/sub/path' 或 'name/sub' 归一成包名。
normalize() {
  awk -F/ '{ if ($0 ~ /^@/) { print $1 "/" $2 } else if ($0 != "") { print $1 } }'
}

: > "$EXTRAS"
for round in 1 2 3 4 5 6 7 8; do
  mapfile -t EXTRA_ARGS < <(grep -v '^$' "$EXTRAS" | sort -u)
  "$NODE" "$P/scripts/engine-prune/ship-from-dump.mjs" "$DUMP" "$R/official-engine/node_modules" "$LIST" "${EXTRA_ARGS[@]}" 2>/dev/null | head -1
  rm -rf "$W"; mkdir -p "$W/tree/node_modules" "$W/home"
  tar -C "$R/official-engine/node_modules" -czf "$W/engine.tgz" -T "$LIST" || { echo TAR_FAILED; exit 1; }
  tar -C "$W/tree/node_modules" -xzf "$W/engine.tgz"
  ( cd "$W/tree" && DSH_HOME="$W/home" "$NODE" node_modules/@deepseek-ai/dsh/lib/bin.js --profile sdk --dump-config > "$W/dump.yml" 2> "$W/dump.err" )
  entries=$(grep -c "name: '" "$W/dump.yml")
  missing=$( { grep -oE "Cannot find (package|module) '[^']+'" "$W/dump.err" | sed "s/.*'\(.*\)'/\1/"; \
               grep -oE 'cannot resolve profile bundle "[^"]+"' "$W/dump.err" | sed 's/.*"\(.*\)"/\1/'; } | normalize | sort -u)
  echo "round $round: entries=$entries tarball=$(stat -c%s "$W/engine.tgz") missing=$(echo $missing)"
  if [ -z "$missing" ] && [ "$entries" -ge 100 ]; then
    echo "SHIP_LIST_OK entries=$entries tarball=$(stat -c%s "$W/engine.tgz")"
    exit 0
  fi
  [ -z "$missing" ] && { echo "SHIP_LIST_STALLED"; head -20 "$W/dump.err"; exit 1; }
  printf '%s\n' $missing >> "$EXTRAS"
done
echo "SHIP_LIST_INCOMPLETE"
head -20 "$W/dump.err"
exit 1
