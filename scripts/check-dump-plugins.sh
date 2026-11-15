#!/usr/bin/env bash
set -u
W=/var/tmp/engine-dump-check
echo "plugin entries: $(grep -c "name: '" "$W/dump.yml")"
echo '=== unique package names ==='
grep "name: '" "$W/dump.yml" | sed "s/.*name: '//; s/'.*//" | sort -u | head -40
echo '=== dsh-base mentions ==='
grep -c 'dsh-base' "$W/dump.yml" || true
