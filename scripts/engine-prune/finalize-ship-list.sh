#!/usr/bin/env bash
# 重新生成引擎文件清单并做三重复核：
#   1. 静态 import 扫描：清单内每个 .js 的裸包依赖是否都在包里；
#   2. sdk profile 的 --dump-config；
#   3. web profile 的 --dump-config。
# 任何一步有缺口就把缺的包并进闭包重来，最多 10 轮。
set -uo pipefail
R=/var/tmp/deepseek-harmony-native
P=/mnt/d/forGithub/deepseek-harmony
NODE="$R/host-node/bin/node"
NM="$R/official-engine/node_modules"
LIST="$P/scripts/engine-ship-files.txt"
EXTRAS=/var/tmp/engine-ship-extras.txt
W=/var/tmp/engine-ship-verify
DUMP=/var/tmp/dump-all.yml

cat /var/tmp/engine-dump-full/dump.yml /var/tmp/engine-web-check/dump.yml > "$DUMP"
: > "$EXTRAS"

for round in 1 2 3 4 5 6 7 8 9 10; do
  mapfile -t EXTRA_ARGS < <(grep -v '^$' "$EXTRAS" | sort -u)
  "$NODE" "$P/scripts/engine-prune/ship-from-dump.mjs" "$DUMP" "$NM" "$LIST" "${EXTRA_ARGS[@]}" 2>/dev/null | head -1

  "$NODE" "$P/scripts/engine-prune/scan-imports.mjs" "$LIST" "$NM" /tmp/import-missing.txt | head -20
  if [ -s /tmp/import-missing.txt ]; then
    echo "round $round: import 扫描发现缺包，加入闭包"
    cat /tmp/import-missing.txt >> "$EXTRAS"
    continue
  fi

  rm -rf "$W"; mkdir -p "$W/tree/node_modules" "$W/home"
  tar -C "$NM" -czf "$W/engine.tgz" -T "$LIST" || { echo TAR_FAILED; exit 1; }
  tar -C "$W/tree/node_modules" -xzf "$W/engine.tgz"

  failed=0
  for profile in sdk web; do
    ( cd "$W/tree" && DSH_HOME="$W/home/$profile" "$NODE" node_modules/@deepseek-ai/dsh/lib/bin.js \
        --profile "$profile" --dump-config > "$W/$profile.yml" 2> "$W/$profile.err" )
    entries=$(grep -c "name: '" "$W/$profile.yml")
    echo "round $round profile=$profile: entries=$entries"
    if [ "$entries" -lt 100 ]; then
      failed=1
      { grep -oE "Cannot find (package|module) '[^']+'" "$W/$profile.err" | sed "s/.*'\(.*\)'/\1/"; 
        grep -oE 'cannot resolve profile bundle "[^"]+"' "$W/$profile.err" | sed 's/.*"\(.*\)"/\1/'; } \
        | awk -F/ '{ if ($0 ~ /^@/) print $1 "/" $2; else if ($0 != "") print $1 }' \
        | sort -u >> "$EXTRAS"
    fi
  done
  if [ "$failed" -eq 0 ]; then
    echo "SHIP_LIST_OK files=$(grep -c '' "$LIST") tarball=$(stat -c%s "$W/engine.tgz")"
    exit 0
  fi
done

echo SHIP_LIST_INCOMPLETE
head -20 "$W/web.err"
exit 1
