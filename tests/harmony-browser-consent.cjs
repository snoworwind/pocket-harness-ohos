'use strict';
// Logic only: transpilation does not validate ArkUI/SDK or device behavior.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/BrowserConsent.ets'), 'utf8');
const start = source.indexOf('export class BrowserConsentControl');
const end = source.indexOf('\n@Component', start);
assert.ok(start >= 0 && end > start);
const js = ts.transpileModule(source.slice(start, end), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const sandbox = { exports: {}, setTimeout, clearTimeout }; vm.runInNewContext(js, sandbox);
const { BrowserConsentControl } = sandbox.exports;
const approval = () => ({ sessionId: 'session', operation: 'open', pageTitle: 'title', pageUrl: 'https://current.test/path', targetUrl: 'https://target.test/path' });
test('single request, copy details and explicit decision', async () => {
  const c = new BrowserConsentControl(); let shown, token;
  assert.equal(await c.request(approval()), false);
  assert.equal(c.attach((details, id) => { shown = details; token = id; }), true);
  assert.equal(c.attach(() => {}), false);
  const data = approval(), p = c.request(data); data.targetUrl = 'changed';
  assert.equal(shown.targetUrl, 'https://target.test/path');
  assert.equal(await c.request(approval()), false);
  c.decide(token, true); assert.equal(await p, true); assert.equal(shown, null);
});
test('scroll direction is copied into the native approval', async () => {
  const c = new BrowserConsentControl(); let shown, token;
  c.attach((details, id) => { shown = details; token = id; });
  const data = { ...approval(), operation: 'scroll', direction: 'up' };
  const p = c.request(data); data.direction = 'down';
  assert.equal(shown.direction, 'up'); c.decide(token, true); assert.equal(await p, true);
  assert.match(source, /400vp/); assert.match(source, /网络请求和页面脚本/);
});
test('cancel, timeout, destruction and late clicks deny', async () => {
  const c = new BrowserConsentControl(); let token;
  c.attach((_details, id) => { token = id; });
  const p = c.request(approval()); const stale = token; c.cancel(); assert.equal(await p, false);
  const p2 = c.request(approval()); c.decide(stale, true); c.decide(token, false); assert.equal(await p2, false);
  assert.equal(await c.request(approval(), 1), false);
  const p3 = c.request(approval()); const last = token; c.destroy(); c.decide(last, true);
  assert.equal(await p3, false); assert.equal(await c.request(approval()), false);
});
test('invalid timeouts and presentation errors fail closed', async () => {
  const c = new BrowserConsentControl(); c.attach(() => { throw Error('failed'); });
  assert.equal(await c.request(approval(), 0), false);
  assert.equal(await c.request(approval(), Infinity), false);
  assert.equal(await c.request(approval()), false);
});
