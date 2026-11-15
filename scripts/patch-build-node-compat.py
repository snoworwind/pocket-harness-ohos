#!/usr/bin/env python3
"""把 libcxx ABI 兼容对象接进 libnode.so 的重链接（按行插入，避免空白差异）。"""
import sys

PATHS = [
    '/var/tmp/deepseek-harmony-native/iec/scripts/optional/build_node.sh',
    '/mnt/d/forGithub/deepseek-harmony/native/iec/scripts/optional/build_node.sh',
]

COMPILE_LINES = [
    '\n',
    '\t# 补随包 libc++_shared 缺失的符号（std::__n1::__hash_memory）。\n',
    '\t$CXX_TARGET -O2 -fPIC -std=c++17 \\\n',
    '\t\t-c "$IEC_ROOT/scripts/optional/node-ohos/libcxx_abi_compat.cc" \\\n',
    '\t\t-o "$BUILD/iec_libcxx_compat.o"\n',
]

for path in PATHS:
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()
    if any('iec_libcxx_compat.o' in line for line in lines):
        print('already patched:', path)
        continue

    compile_at = None
    link_at = None
    for i, line in enumerate(lines):
        if compile_at is None and 'loader/wrap.c' in line and 'iec_dlopen_wrap.o' in line:
            compile_at = i + 1
        if link_at is None and 'iec_guest_switch.o' in line and 'iec_dlopen_wrap.o' in line:
            link_at = i + 1
    if compile_at is None or link_at is None:
        print(f'anchors not found: {path} compile={compile_at} link={link_at}', file=sys.stderr)
        sys.exit(1)

    # 先插 link，避免索引变化；relink 行内是转义引号 \"$BUILD/...\"。
    lines.insert(link_at, '\t\t\\"$BUILD/iec_libcxx_compat.o\\" \\\n')
    lines[compile_at:compile_at] = COMPILE_LINES
    with open(path, 'w', encoding='utf-8') as f:
        f.writelines(lines)
    print('patched:', path)
