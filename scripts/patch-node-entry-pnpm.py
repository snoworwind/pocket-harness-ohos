#!/usr/bin/env python3
"""给 libnode.so 增加 iec_pnpm_main 入口，让 DSH 插件管理器能直接调用 pnpm。

插件管理器用 `execa(config.pnpmCommand ?? "pnpm")` 装插件；鸿蒙侧只能执行
IEC 的命令启动器（.so + C 入口），所以 pnpm 不能是一个 shell 脚本，必须在
libnode.so 里有一个入口，用 node 跑 `<sysroot>/engine/node_modules/pnpm/bin/pnpm.cjs`。
"""
import sys

PATHS = [
    '/var/tmp/deepseek-harmony-native/iec/scripts/optional/node-ohos/iec_node_entry.cc',
    '/mnt/d/forGithub/deepseek-harmony/native/iec/scripts/optional/node-ohos/iec_node_entry.cc',
]

ANCHOR = '''extern "C" int iec_npx_main(int argc, char **argv)
{
    return RunNodeCli("/npm/bin/npx-cli.js", argc, argv);
}
'''
ADD = ANCHOR + '''
extern "C" int iec_pnpm_main(int argc, char **argv)
{
    // 随引擎归档分发的 pnpm（pack-native.sh 解到 engine/node_modules/pnpm）。
    return RunNodeCli("/engine/node_modules/pnpm/bin/pnpm.cjs", argc, argv);
}
'''

for path in PATHS:
    with open(path, encoding='utf-8') as f:
        src = f.read()
    if 'iec_pnpm_main' in src:
        print('already patched:', path)
        continue
    if ANCHOR not in src:
        print('anchor missing:', path, file=sys.stderr)
        sys.exit(1)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src.replace(ANCHOR, ADD, 1))
    print('patched:', path)
