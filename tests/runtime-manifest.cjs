'use strict';
// 宿主测试：运行时版本摘要。
//
// 哈希不在清单里落盘（由 build.mjs / pack-native.sh 在构建时算），所以这里用合成
// 的归档摘要直接测纯函数：同一批输入版本稳定，任一归档或命令表变化必须换版本，
// 且摘要域只包含四个会被解包的归档。
const test = require('node:test');
const assert = require('node:assert/strict');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

const root = join(__dirname, '..');

async function api() {
  return import(pathToFileURL(join(root, 'scripts/runtime-manifest.mjs')).href);
}

function manifest() {
  return {
    version: '0.2.2-rc.1-000000000000',
    engineVersion: '0.2.2-rc.1',
    nodeVersion: '24.22.1',
    commands: [
      { name: 'bash', library: 'libbash.so', entry: 'iec_bash_main', arity: 3 },
      { name: 'node', library: 'libnode.so', entry: 'iec_node_main' },
    ],
  };
}

function artifacts(overrides = {}) {
  const base = {
    'official-engine.tar.gz': 'a'.repeat(64),
    'npm.tar.gz': 'b'.repeat(64),
    'python-stdlib.tar': 'c'.repeat(64),
    'vim-runtime.tar.gz': 'd'.repeat(64),
  };
  return { ...base, ...overrides };
}

test('same inputs produce the same version', async () => {
  const { runtimeVersion } = await api();
  assert.equal(runtimeVersion(manifest(), artifacts()), runtimeVersion(manifest(), artifacts()));
});

test('changing any archive hash changes the version', async () => {
  const { runtimeVersion } = await api();
  const before = runtimeVersion(manifest(), artifacts());
  for (const name of ['official-engine.tar.gz', 'npm.tar.gz', 'python-stdlib.tar', 'vim-runtime.tar.gz']) {
    assert.notEqual(runtimeVersion(manifest(), artifacts({ [name]: 'e'.repeat(64) })), before, name);
  }
});

test('changing the command table changes the version', async () => {
  const { runtimeVersion } = await api();
  const before = runtimeVersion(manifest(), artifacts());
  const changed = manifest();
  changed.commands[1].arity = 3;
  assert.notEqual(runtimeVersion(changed, artifacts()), before);
});

test('hash letter case and key order do not change the version', async () => {
  const { runtimeVersion } = await api();
  const upper = Object.fromEntries(Object.entries(artifacts()).reverse().map(([name, hash]) => [name, hash.toUpperCase()]));
  assert.equal(runtimeVersion(manifest(), upper), runtimeVersion(manifest(), artifacts()));
});

test('missing archive hash is rejected', async () => {
  const { runtimeVersion } = await api();
  const incomplete = artifacts();
  delete incomplete['npm.tar.gz'];
  assert.throws(() => runtimeVersion(manifest(), incomplete), /缺少归档 npm\.tar\.gz/);
});

test('digest domain is only the four unpacked archives', async () => {
  const { ARTIFACTS } = await api();
  // 原生库与壳层插件都不在摘要域里：改它们不应换运行时目录。
  assert.deepEqual([...ARTIFACTS].sort(), [
    'npm.tar.gz',
    'official-engine.tar.gz',
    'python-stdlib.tar',
    'vim-runtime.tar.gz',
  ]);
});
