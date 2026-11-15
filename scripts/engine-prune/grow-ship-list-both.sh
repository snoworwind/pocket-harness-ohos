#!/usr/bin/env bash
# 迭代补齐：反复验证裁剪后的引擎树，直到 sdk 与 web 两个 profile 都能完整解析。
# 与 grow-ship-list.sh 的区别：闭包根取两份 dump 的并集，并且两个 profile 都要通过。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
DUMP=/var/tmp/dump-all.yml
LIST="$P/scripts/engine-ship-files.txt"
EXTRAS=/var/tmp/engine-ship-extras.txt
W=/var/tmp/engine-ship-verify
NODE="$R/host-node/bin/node"
NM="$R/official-engine/node_modules"

normalize() {
  awk -F/ '{ if ($0 ~ /^@/) { print $1 "/" $2 } else if ($0 != "") { print $1 } }'
}

# sdk 与 web 的两份 dump 合成一个闭包根集合。
cat /var/tmp/engine-dump-full/dump.yml /var/tmp/engine-web-check/dump.yml > "$DUMP"

: > "$EXTRAS"
for round in 1 2 3 4 5 6 7 8 9 10; do
  mapfile -t EXTRA_ARGS < <(grep -v '^$' "$EXTRAS" | sort -u)
  "$NODE" "$P/scripts/engine-prune/ship-from-dump.mjs" "$DUMP" "$NM" "$LIST" "${EXTRA_ARGS[@]}" 2>/dev/null | head -1
  rm -rf "$W"; mkdir -p "$W/tree/node_modules" "$W/home"
  tar -C "$NM" -czf "$W/engine.tgz" -T "$LIST" || { echo TAR_FAILED; exit 1; }
  tar -C "$W/tree/node_modules" -xzf "$W/engine.tgz"

  total_missing=''
  for profile in sdk web; do
    ( cd "$W/tree" && DSH_HOME="$W/home/$profile" "$NODE" node_modules/@deepseek-ai/dsh/lib/bin.js \
        --profile "$profile" --dump-config > "$W/$profile.yml" 2> "$W/$profile.err" )
    entries=$(grep -c "name: '" "$W/$profile.yml")
    missing=$( { grep -oE "Cannot find (package|module) '[^']+'" "$W/$profile.err" | sed "s/.*'\(.*\)'/\1/"; \
                 grep -oE 'cannot resolve profile bundle "[^"]+"' "$W/$profile.err" | sed 's/.*"\(.*\)"/\1/'; } | normalize | sort -u)
    echo "round $round profile=$profile: entries=$entries missing=$(echo $missing)"
    total_missing="$total_missing $missing"
    if [ "$profile" = web ] && [ -z "$(echo "$total_missing" | tr ' ' '\n' | grep -v '^$')" ] && [ "$entries" -ge 200 ]; then
      echo "SHIP_LIST_OK tarball=$(stat -c%s "$W/engine.tgz")"
      exit 0
    fi
  done
  missing_all=$(echo "$total_missing" | tr ' ' '\n' | grep -v '^$' | sort -u)
  [ -z "$missing_all" ] && { echo 'SHIP_LIST_STALLED'; head -20 "$W/web.err"; exit 1; }
  printf '%s\n' $missing_all >> "$EXTRAS"
done
echo 'SHIP_LIST_INCOMPLETE'
head -20 "$W/web.err"
exit 1
