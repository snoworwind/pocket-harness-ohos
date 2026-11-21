'use strict';
// 宿主测试：PluginGuard 的隔离/恢复/一次性自动恢复逻辑。
// PluginGuard.ets 依赖 @kit.AbilityKit 与 @kit.CoreFileKit，这里用内存文件系统
// 替换掉 fileIo，只验证纯逻辑（配置保存、目录搬移、失败回滚、自动恢复次数）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sourcePath = path.join(root, 'entry/src/main/ets/platform/PluginGuard.ets');
const ts = (() => {
  const candidates = [process.env.TYPESCRIPT_PATH, 'typescript', process.env.DEVECO_HOME &&
    path.join(process.env.DEVECO_HOME, 'tools/hvigor/hvigor/node_modules/typescript'),
    'D:/D Program Files/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript'];
  for (const candidate of candidates.filter(Boolean)) {
    try { return require(candidate); } catch (error) { /* try next */ }
  }
  throw new Error('Install TypeScript or set TYPESCRIPT_PATH');
})();

// 最小内存文件系统：只实现 PluginGuard 用到的同步 API。
function makeStore() {
  return { dirs: new Set(['/']), files: new Map(), fds: new Map(), nextFd: 1 };
}

function ensureDir(store, dir) {
  const parts = dir.split('/').filter(Boolean);
  let current = '';
  for (const part of parts) {
    current += '/' + part;
    store.dirs.add(current);
  }
}

function putFile(store, file, content) {
  ensureDir(store, path.posix.dirname(file));
  store.files.set(file, content);
}

function childrenOf(store, dir) {
  const prefix = dir.endsWith('/') ? dir : dir + '/';
  const names = new Set();
  for (const candidate of [...store.dirs, ...store.files.keys()]) {
    if (candidate === dir || !candidate.startsWith(prefix)) continue;
    const rest = candidate.slice(prefix.length);
    if (rest === '') continue;
    names.add(rest.split('/')[0]);
  }
  return [...names];
}

function makeFileIo(store) {
  const fsMock = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    accessSync(target) { return store.dirs.has(target) || store.files.has(target); },
    readTextSync(target) {
      if (!store.files.has(target)) throw new Error('ENOENT ' + target);
      return store.files.get(target);
    },
    openSync(target, mode) {
      const fd = store.nextFd++;
      if (mode & fsMock.OpenMode.TRUNC && store.files.has(target)) store.files.set(target, '');
      if (!store.files.has(target)) store.files.set(target, '');
      store.fds.set(fd, target);
      return { fd };
    },
    writeSync(fd, text) { store.files.set(store.fds.get(fd), String(text)); },
    closeSync(fd) { store.fds.delete(fd); },
    renameSync(from, to) {
      if (store.files.has(from)) {
        const content = store.files.get(from);
        store.files.delete(from);
        store.files.set(to, content);
        return;
      }
      if (!store.dirs.has(from)) throw new Error('ENOENT ' + from);
      const prefix = from + '/';
      for (const file of [...store.files.keys()]) {
        if (file.startsWith(prefix)) {
          const content = store.files.get(file);
          store.files.delete(file);
          store.files.set(to + file.slice(from.length), content);
        }
      }
      for (const dir of [...store.dirs]) {
        if (dir === from) { store.dirs.delete(dir); store.dirs.add(to); continue; }
        if (dir.startsWith(prefix)) {
          store.dirs.delete(dir);
          store.dirs.add(to + dir.slice(from.length));
        }
      }
    },
    listFileSync(dir) {
      if (!store.dirs.has(dir)) throw new Error('ENOENT ' + dir);
      return childrenOf(store, dir);
    },
    lstatSync(target) {
      if (!store.dirs.has(target) && !store.files.has(target)) throw new Error('ENOENT ' + target);
      return { isDirectory: () => store.dirs.has(target) };
    },
    mkdirSync(dir) { ensureDir(store, dir); },
    rmdirSync(dir) {
      if (childrenOf(store, dir).length > 0) throw new Error('ENOTEMPTY ' + dir);
      store.dirs.delete(dir);
    },
    unlinkSync(file) { store.files.delete(file); }
  };
  return fsMock;
}

function loadGuard(store) {
  // 每次都重新转译并按当前 store 注入 fileIo，避免测试之间共享模块级状态。
  const code = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  const requireMock = (name) => {
    if (name === '@kit.AbilityKit') return { common: {} };
    if (name === '@kit.CoreFileKit') return { fileIo: makeFileIo(store) };
    return require(name);
  };
  new Function('require', 'module', 'exports', code)(requireMock, module, module.exports);
  return new module.exports.PluginGuard({ filesDir: '/files' });
}

function seedProfile(store, bundles, pluginDirs) {
  putFile(store, '/files/harness-home/profiles/web/package.json', JSON.stringify({
    name: 'web', dsh: { profile: { bundles } }
  }, null, 2));
  for (const dir of pluginDirs) ensureDir(store, '/files/harness-home/profiles/web/node_modules/' + dir);
}

function readBundles(store) {
  return JSON.parse(store.files.get('/files/harness-home/profiles/web/package.json')).dsh.profile.bundles;
}

test('quarantine 保存完整原配置并只隔离第三方包', () => {
  const store = makeStore();
  seedProfile(store, ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a', '@test/b'],
    ['@test/a', '@test/b']);
  const guard = loadGuard(store);
  const result = guard.quarantine('上次启动未完成');
  assert.deepStrictEqual(result.moved.sort(), ['@test/a', '@test/b']);
  assert.strictEqual(result.error, '');
  assert.deepStrictEqual(readBundles(store), ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']);
  const state = JSON.parse(store.files.get('/files/harness-home/plugin-quarantine.json'));
  assert.deepStrictEqual(state.records[0].originalBundles,
    ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a', '@test/b']);
  assert.ok(store.dirs.has('/files/harness-home/plugin-quarantine/' + state.records[0].time.replace(/[:.]/g, '-')));
});

test('restore 把包和完整配置都还原，并删除隔离记录', () => {
  const store = makeStore();
  seedProfile(store, ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a', '@test/b'],
    ['@test/a', '@test/b']);
  const guard = loadGuard(store);
  guard.quarantine('上次启动未完成');
  const error = guard.restoreLastQuarantine();
  assert.strictEqual(error, '');
  assert.deepStrictEqual(readBundles(store),
    ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a', '@test/b']);
  assert.strictEqual(guard.hasQuarantine(), false);
  assert.ok(store.dirs.has('/files/harness-home/profiles/web/node_modules/@test/a'));
});

test('一个包目录缺失时保留它的配置，并且不改配置', () => {
  const store = makeStore();
  seedProfile(store, ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/missing'],
    []);
  const guard = loadGuard(store);
  const result = guard.quarantine('上次启动未完成');
  assert.deepStrictEqual(result.moved, []);
  assert.match(result.error, /目录不存在/);
  assert.deepStrictEqual(readBundles(store),
    ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/missing']);
});

test('恢复时源目录丢失会保留记录并返回错误', () => {
  const store = makeStore();
  seedProfile(store, ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a'], ['@test/a']);
  const guard = loadGuard(store);
  guard.quarantine('上次启动未完成');
  // 手工删掉隔离目录里的包（文件和目录都移除），模拟半恢复/文件丢失。
  for (const file of [...store.files.keys()]) {
    if (file.includes('/plugin-quarantine/')) store.files.delete(file);
  }
  for (const dir of [...store.dirs]) {
    if (dir.includes('/plugin-quarantine/')) store.dirs.delete(dir);
  }
  const error = guard.restoreLastQuarantine();
  assert.match(error, /恢复未完成/);
  assert.strictEqual(guard.hasQuarantine(), true);
  assert.strictEqual(guard.quarantineCount(), 1);
});

test('崩溃导致的隔离只自动恢复一次，插件失败导致的隔离不自动恢复', () => {
  const crashStore = makeStore();
  seedProfile(crashStore, ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a'], ['@test/a']);
  const crashGuard = loadGuard(crashStore);
  crashGuard.quarantine('上次启动未完成');
  assert.strictEqual(crashGuard.canAutoRestore(), true);
  crashGuard.markAutoRestoreAttempted();
  assert.strictEqual(crashGuard.canAutoRestore(), false);

  const pluginStore = makeStore();
  seedProfile(pluginStore, ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', '@test/a'], ['@test/a']);
  const pluginGuard = loadGuard(pluginStore);
  pluginGuard.quarantine('Cannot find module @test/a');
  assert.strictEqual(pluginGuard.canAutoRestore(), false);
});
