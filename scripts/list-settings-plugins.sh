#!/bin/bash
# 列出各 settings 伴随插件的 client.js 大小，挑一个最小样本学习注册方式。
for d in /var/tmp/deepseek-harmony-native/official-engine/node_modules/@deepseek-ai/dsh-client-ui-settings-*; do
  f="$d/lib/client.js"
  [ -f "$f" ] || continue
  printf '%8d  %s\n' "$(stat -c%s "$f")" "$(basename "$d")"
done | sort -n | head -10
