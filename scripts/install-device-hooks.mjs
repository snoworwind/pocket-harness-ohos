#!/usr/bin/env node
/**
 * 设备端钩子安装器（HarmonyOS 沙箱专用）。
 *
 *   node scripts/install-device-hooks.mjs
 *
 * 为什么需要单独一份：应用进程不能 execve 普通脚本，`#!/bin/sh` 在设备上
 * 解析不到解释器，钩子会以 127 失败、每次提交/推送直接报错。所以 `.git/hooks/`
 * 里的包装脚本必须把 shebang 写成当次运行时 `runtime-<ver>/bin/sh` 的绝对路径。
 *
 * 运行时会随应用升级整棵重建（路径里的版本号会变），旧路径一旦被清理，钩子
 * 就会再次 127 失败。升级后重跑本脚本即可。
 *
 * 本脚本只改本仓库 `.git/hooks/` 下的两个文件，不动 `.githooks/` 源码，也不
 * 启用 `core.hooksPath`（那会让 git hook run 走 `#!/bin/sh` 而失败）。
 */
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hooksDir = path.join(root, '.git', 'hooks');

function fail(message) {
  console.error('install-device-hooks: ' + message);
  process.exit(1);
}

/** 当前运行时根目录：优先环境变量，否则在 files/ 下挑最新的可用 runtime-*。 */
function resolveSysroot() {
  const usable = (dir) => {
    if (typeof dir !== 'string' || dir === '') return false;
    return existsSync(path.join(dir, 'bin', 'sh')) && existsSync(path.join(dir, 'bin', 'node'));
  };
  const fromEnv = process.env.IEC_SYSROOT;
  if (usable(fromEnv)) return fromEnv;
  const filesDir = process.env.DSH_HOME ? path.dirname(process.env.DSH_HOME) : '';
  if (filesDir === '' || !existsSync(filesDir)) return '';
  const found = readdirSync(filesDir)
    .filter((name) => name.startsWith('runtime-'))
    .map((name) => path.join(filesDir, name))
    .filter(usable)
    .map((dir) => ({ dir, mtime: statSync(path.join(dir, 'bin', 'node')).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  return found.length > 0 ? found[0].dir : '';
}

const sysroot = resolveSysroot();
if (sysroot === '') {
  fail('找不到可用的运行时（需要 runtime-*/bin/sh 与 bin/node）；请先启动一次应用，' +
    '或设置 IEC_SYSROOT 指向当前运行时根目录。');
}

const sh = path.join(sysroot, 'bin', 'sh');
const node = path.join(sysroot, 'bin', 'node');

if (!existsSync(hooksDir)) mkdirSync(hooksDir, { recursive: true });

/** shebang 后的一行注释要说明「升级会失效，重跑本脚本」。 */
function wrapper(comment, command) {
  return [
    '#!' + sh,
    '# 本机生成：设备上 #!/bin/sh 不可执行，shebang 必须指向 IEC 启动器真实路径。',
    '# 应用升级会整棵重建 runtime-<ver>；若钩子报 127，重跑：',
    '#   node scripts/install-device-hooks.mjs',
    '# ' + comment,
    'exec ' + JSON.stringify(node) + ' ' + command,
    ''
  ].join('\n');
}

const hooks = [
  ['pre-commit', wrapper('提交门禁：暂存区里出现敏感文件/凭据时拒绝提交。', '.githooks/secret-scan.mjs --staged')],
  ['pre-push', wrapper('推送门禁：本次要推送的提交里出现敏感文件/凭据时拒绝推送。', '.githooks/secret-scan.mjs --pre-push')]
];
for (const [name, text] of hooks) {
  const file = path.join(hooksDir, name);
  writeFileSync(file, text);
  chmodSync(file, 0o755);
}

// core.hooksPath 指向 .githooks 时，git 会直接执行 `#!/bin/sh` 的模板脚本并 127 失败。
try {
  const configured = execFileSync('git', ['config', '--local', '--get', 'core.hooksPath'],
    { cwd: root, encoding: 'utf8' }).trim();
  if (configured !== '') {
    if (configured === '.githooks') {
      execFileSync('git', ['config', '--local', '--unset', 'core.hooksPath'], { cwd: root });
      console.log('已清除 core.hooksPath=.githooks（它会绕过本机包装脚本）。');
    } else {
      console.warn('注意：core.hooksPath=' + configured + ' 会覆盖 .git/hooks，本脚本安装的钩子不会生效。');
    }
  }
} catch {
  // `git config --get` 未命中时返回非零，属正常情况。
}

console.log('已安装设备端钩子（运行时：' + sysroot + '）：');
for (const [name] of hooks) console.log('  .git/hooks/' + name);
