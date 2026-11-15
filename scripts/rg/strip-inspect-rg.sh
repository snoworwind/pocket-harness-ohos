#!/usr/bin/env bash
set -u
R=/var/tmp/deepseek-harmony-native
SO=/var/tmp/dsh-rg/librg.so
STRIP=$R/sdk/native/llvm/bin/llvm-strip
READELF=$R/sdk/native/llvm/bin/llvm-readelf
NM=$R/sdk/native/llvm/bin/llvm-nm
echo "before: $(stat -c%s "$SO")"
$STRIP --strip-unneeded "$SO"
echo "after:  $(stat -c%s "$SO")"
echo '=== dynamic ==='
$READELF -d "$SO" | grep -E 'NEEDED|SONAME'
echo '=== undefined (first 15) ==='
$NM -D -u "$SO" | head -15
echo '=== unresolved count ==='
$NM -D -u "$SO" | wc -l
