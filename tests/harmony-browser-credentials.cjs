'use strict';
// Node host simulation only: NOT an ArkTS compiler or HarmonyOS filesystem test.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/platform/BrowserCredentials.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'credential-test-'));
  const timers = new Map(); let next = 0;
  const api = {
    OpenMode: { CREATE: fs.constants.O_CREAT, EXCL: fs.constants.O_EXCL, WRITE_ONLY: fs.constants.O_WRONLY },
    lstatSync: fs.lstatSync, mkdirSync: p => fs.mkdirSync(p, { mode: 0o700 }),
    listFileSync: fs.readdirSync, rmdirSync: p => fs.rmSync(p, { recursive: true }), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
    readTextSync: p => fs.readFileSync(p, 'utf8'),
    openSync: (p, flags) => ({ fd: fs.openSync(p, flags, 0o600) }),
    closeSync: f => fs.closeSync(f.fd),
    writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
  };
  const sandbox = { exports: {}, Date, setTimeout: fn => { timers.set(++next, fn); return next; },
    clearTimeout: id => timers.delete(id), require: name => {
      if (name === '@kit.CoreFileKit') return { fileIo: api };
      assert.equal(name, '@kit.ArkTS'); return { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } };
    } };
  vm.runInNewContext(js, sandbox);
  return { root, api, timers, Publisher: sandbox.exports.BrowserCredentials, target: path.join(root, 'browser-managed/ready.json'),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}
const ready = { host: '127.0.0.1', port: 12345, credential: 'a'.repeat(64) };
const verify = (p, directory) => { const stat = fs.lstatSync(p); return (stat.mode & 0o077) === 0 && (directory ? stat.isDirectory() : stat.isFile()); };

test('atomic complete publication, singleton and stop', async () => {
  const s = setup(); try {
    const a = new s.Publisher(s.root, verify), b = new s.Publisher(s.root, verify);
    const before = Date.now(); await a.deliverReady(ready);
    const value = JSON.parse(fs.readFileSync(s.target, 'utf8'));
    assert.deepEqual({ ...value, expiresAt: 0 }, { version: 1, host: ready.host, port: ready.port, credential: ready.credential, expiresAt: 0 });
    assert.ok(value.expiresAt >= before && value.expiresAt <= Date.now() + 300000);
    await assert.rejects(b.deliverReady(ready)); a.stop(); assert.ok(!fs.existsSync(s.target));
    await assert.rejects(a.deliverReady(ready));
  } finally { s.cleanup(); }
});
test('old stop preserves replacement and timer revokes', async () => {
  const s = setup(); try {
    const a = new s.Publisher(s.root, verify); await a.deliverReady(ready);
    fs.writeFileSync(s.target, 'replacement'); a.stop(); assert.equal(fs.readFileSync(s.target, 'utf8'), 'replacement');
    const b = new s.Publisher(s.root, verify); await b.deliverReady(ready);
    [...s.timers.values()][0](); assert.equal(fs.existsSync(s.target), false);
  } finally { s.cleanup(); }
});
test('rejects symlinks and existing temporary file without touching them', async () => {
  const s = setup(); try {
    const dir = path.dirname(s.target); fs.mkdirSync(dir, { mode: 0o700 }); fs.symlinkSync('/missing', s.target);
    await assert.rejects(new s.Publisher(s.root, verify).deliverReady(ready)); assert.ok(fs.lstatSync(s.target).isSymbolicLink());
    fs.unlinkSync(s.target); const tempDir = path.join(dir, 'ready.tmp'); fs.symlinkSync('/missing', tempDir);
    await assert.rejects(new s.Publisher(s.root, verify).deliverReady(ready)); assert.ok(fs.lstatSync(tempDir).isSymbolicLink());
  } finally { s.cleanup(); }
});
test('partial writes and failure do not expose incomplete target', async () => {
  const s = setup(); try {
    const write = s.api.writeSync; let calls = 0;
    s.api.writeSync = (fd, data) => { if (++calls === 2) throw Error('failure'); return write(fd, data.slice(0, 4)); };
    await assert.rejects(new s.Publisher(s.root, verify).deliverReady(ready));
    assert.equal(fs.existsSync(s.target), false); assert.equal(fs.existsSync(path.join(path.dirname(s.target), 'ready.tmp')), false);
  } finally { s.cleanup(); }
});
test('unexpected temporary entries survive recursive rmdir on both paths', async () => {
  for (const failWrite of [false, true]) {
    const s = setup(); try {
      const tempDir = path.join(path.dirname(s.target), 'ready.tmp');
      const unexpected = path.join(tempDir, 'unexpected');
      if (failWrite) {
        s.api.writeSync = () => { fs.writeFileSync(unexpected, 'preserve'); throw Error('write failed'); };
      } else {
        const rename = s.api.renameSync;
        s.api.renameSync = (from, to) => { rename(from, to); fs.writeFileSync(unexpected, 'preserve'); };
      }
      await assert.rejects(new s.Publisher(s.root, verify).deliverReady(ready));
      assert.equal(fs.readFileSync(unexpected, 'utf8'), 'preserve');
      assert.equal(fs.existsSync(s.target), false);
    } finally { s.cleanup(); }
  }
});
test('stop before queued promise and invalid input fail closed', async () => {
  const s = setup(); try {
    await assert.rejects(new s.Publisher(s.root).deliverReady(ready));
    await assert.rejects(new s.Publisher(s.root, () => false).deliverReady(ready));
    const a = new s.Publisher(s.root, verify); a.stop(); await assert.rejects(a.deliverReady(ready));
    await assert.rejects(new s.Publisher(s.root, verify).deliverReady({ ...ready, credential: 'bad' }));
    await assert.rejects(new s.Publisher(s.root, verify).deliverReady({ ...ready, host: 'localhost' }));
    assert.equal(fs.existsSync(s.target), false);
  } finally { s.cleanup(); }
});
