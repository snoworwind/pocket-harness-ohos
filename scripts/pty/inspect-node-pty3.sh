#!/usr/bin/env bash
set -u
E=/var/tmp/deepseek-harmony-native/official-engine/node_modules/node-pty
echo '=== spawn-helper 用法 ==='
grep -n -A6 -B4 'helperPath' "$E/lib/unixTerminal.js"
echo '=== libutil 是否存在 ==='
ls /var/tmp/deepseek-harmony-native/sdk/native/sysroot/usr/lib/aarch64-linux-ohos/ | grep -i 'util\|util\.so' | head
find /var/tmp/deepseek-harmony-native/sdk/native/sysroot -name 'libutil*' | head
echo '=== pty.cc 头部 ==='
head -40 "$E/src/unix/pty.cc"
