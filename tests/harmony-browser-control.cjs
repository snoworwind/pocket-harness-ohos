'use strict';
// BrowserControl logic simulation; not an ArkUI or ArkWeb integration test.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Browser.ets'), 'utf8');
const begin = source.indexOf('export interface BrowserObservation');
const end = source.indexOf('// 独立 Web 实例');
assert.ok(begin >= 0 && end > begin);
const js = ts.transpileModule(source.slice(begin, end), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const sandbox = { exports: {} }; vm.runInNewContext(js, sandbox);
const { BrowserControl } = sandbox.exports;
test('control requires visible attached browser and matching generation', () => {
  const c = new BrowserControl(); let shown = true, opened = 0;
  c.attach(() => shown, () => { opened++; return true; }, () => ({ generation: 0, title: 'title', url: 'https://example.test/' }));
  assert.equal(c.currentGeneration(), null); c.setVisible(true);
  const first = c.currentGeneration(); assert.notEqual(first, null);
  assert.equal(c.open(first, 'https://example.test/'), true); assert.equal(opened, 1);
  assert.equal(c.observe(first).generation, first);
  c.navigationChanged(); assert.equal(c.open(first, 'https://example.test/'), false); assert.equal(c.observe(first), null);
  const second = c.currentGeneration(); c.setVisible(false); assert.equal(c.currentGeneration(), null);
  c.setVisible(true); assert.notEqual(c.currentGeneration(), second);
  shown = false; assert.equal(c.currentGeneration(), null);
  c.detach(); shown = true; assert.equal(c.currentGeneration(), null);
});
test('native scroll has fixed offsets and rejects stale or invalid input', () => {
  const c = new BrowserControl(), offsets = [];
  c.attach(() => true, () => true, () => ({ generation: 0, title: 't', url: 'https://test/' }), async () => '', n => offsets.push(n));
  c.setVisible(true); const generation = c.currentGeneration();
  c.scroll(generation, 'up'); c.scroll(generation, 'down');
  assert.deepEqual(offsets, [-400, 400]);
  assert.throws(() => c.scroll(generation, 'left'));
  c.pageBegin('https://new.test/'); assert.throws(() => c.scroll(generation, 'up'));
  assert.deepEqual(offsets, [-400, 400]);
});
test('snapshot fails if browser generation changes while pending', async () => {
  const c = new BrowserControl(); let resolve;
  c.attach(() => true, () => true, () => ({ generation: 0, title: 'title', url: 'https://example.test/' }),
    () => new Promise(r => { resolve = r; }));
  c.setVisible(true); const generation = c.currentGeneration();
  const pending = c.snapshot(generation); c.navigationChanged(); resolve('data');
  await assert.rejects(pending, /binding changed/);
});
test('manual rebind requires matching begin, end, visible URL and a fresh generation', () => {
  const c = new BrowserControl(); let visible = true, current = 'https://first.test/';
  c.attach(() => visible, () => true, () => ({ generation: 0, title: 'title', url: current }));
  c.setVisible(true); const generation = c.currentGeneration();
  assert.equal(c.armRebind(generation), true);
  assert.equal(c.rebindPage(), null);
  c.pageEnd(current); assert.equal(c.rebindPage(), null);
  c.pageBegin('https://next.test/'); c.pageEnd('https://old.test/');
  current = 'https://next.test/'; assert.equal(c.rebindPage(), null);
  c.pageEnd(current); assert.equal(c.rebindPage().url, current);
  visible = false; assert.equal(c.rebindPage(), null);
  visible = true; c.consumeRebind(); assert.equal(c.rebindPage(), null);
});

test('navigation during observation invalidates result', () => {
  const c = new BrowserControl();
  c.attach(() => true, () => true, () => { c.navigationChanged(); return { generation: 0, title: 'old', url: 'https://example.test/' }; });
  c.setVisible(true); const epoch = c.currentGeneration();
  assert.equal(c.observe(epoch), null);
});
