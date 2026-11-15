#!/usr/bin/env bash
set -u
W=/var/tmp/engine-dump-check
echo "plugin entries: $(grep -c "name: '" "$W/dump.yml")"
echo "stderr lines: $(wc -l < "$W/dump.err")"
grep -c 'cannot resolve\|not found' "$W/dump.err" || true
head -5 "$W/dump.err"
