'use strict';
// 宿主测试：随包的 harmony-compat 插件与仓库源码一致。
//
// 插件以 rawfile 分发（`entry/.../rawfile/tools/harmony-compat`），启动时覆盖
// 进 profile。以前只从引擎归档同步，归档是 gitignore 的构建产物，忘了重打就会
// 把旧插件装进应用——设置页少了「显示系统状态栏与底部手势条」这一行。这里锁住
// 两份文件的一致性，改插件源码忘了同步 rawfile 时直接失败。
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync, readdirSync, statSync } = require('node:fs');
const { join, relative } = require('node:path');

const root = join(__dirname, '..');
const source = join(root, 'plugins/harmony-compat');
const shipped = join(root, 'entry/src/main/resources/rawfile/tools/harmony-compat');

/** List every regular file below a directory, as sorted relative paths. */
function filesOf(dir) {
  const out = [];
  const walk = (current) => {
    for (const name of readdirSync(current).sort()) {
      const full = join(current, name);
      if (statSync(full).isDirectory()) walk(full);
      else out.push(relative(dir, full).split('\\').join('/'));
    }
  };
  walk(dir);
  return out.sort();
}

test('rawfile harmony-compat ships every plugin source file', () => {
  const expected = filesOf(source);
  assert.deepEqual(filesOf(shipped), expected);
});

test('rawfile harmony-compat matches the plugin sources byte for byte', () => {
  for (const file of filesOf(source)) {
    assert.equal(
      readFileSync(join(shipped, file), 'utf8'),
      readFileSync(join(source, file), 'utf8'),
      `${file} 与 plugins/harmony-compat 不一致，请重新复制到 rawfile`,
    );
  }
});

test('shipped plugin still exposes the system bars switch', () => {
  const host = readFileSync(join(shipped, 'lib/index.js'), 'utf8');
  const client = readFileSync(join(shipped, 'lib/client.js'), 'utf8');
  assert.match(host, /showSystemBars/);
  assert.match(client, /showSystemBars/);
});
