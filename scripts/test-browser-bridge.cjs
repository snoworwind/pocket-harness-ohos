'use strict';
// Run with node scripts/test-browser-bridge.cjs; executes both real ETS classes.
const fs = require('fs');
const vm = require('vm');
const ts = require('typescript');
const assert = require('assert');
function load(path, imports) {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, { module, exports: module.exports, require: name => {
    if (!(name in imports)) throw Error('Unexpected import ' + name);
    return imports[name];
  }, setTimeout, clearTimeout, URL, console }, { filename: path });
  return module.exports;
}
const { BrowserRelay } = load('entry/src/main/ets/platform/BrowserRelay.ets', { '@kit.ArkTS': { url: { URL } } });
const { BrowserBridge } = load('entry/src/main/ets/platform/BrowserBridge.ets', { './BrowserRelay': { BrowserRelay } });
const tick = () => new Promise(resolve => setImmediate(resolve));
const ready = { type: 'ready', version: 1, host: '127.0.0.1', port: 1234, credential: 'a'.repeat(64) };
function setup(authorize = async () => true) {
  const state = { generation: 1, visible: true, session: 'session1', title: 'Title', url: 'https://page.test/', requests: [], writes: [], results: [], opens: [], closed: false, notifications: 0, ready: null };
  state.snapshotCalls = 0;
  state.snapshot = async () => JSON.stringify({ title: 'ignored', url: 'ignored', items: [{ type: 'text', text: 'Hello' }] });
  const control = {
    currentGeneration: () => state.visible ? state.generation : null,
    observe: generation => state.visible && generation === state.generation ? { generation, title: state.title, url: state.url } : null,
    snapshot: async () => { state.snapshotCalls++; return state.snapshot(); },
    armRebind: generation => state.visible && generation === state.generation,
    rebindPage: () => state.rebindReady && state.visible ? { generation: state.generation, title: state.title, url: state.url } : null,
    consumeRebind: () => { state.rebindReady = false; },
    scroll: (generation, direction) => { if (!state.visible || generation !== state.generation) throw Error('binding'); (state.scrolls ||= []).push(direction); },
    open: (generation, target) => { if (!state.visible || generation !== state.generation) return false; state.opens.push(target); state.generation++; return true; }
  };
  const runtime = { startBrowserRelay(output, exit) { state.output = output; state.exit = exit; return {
    close() { state.closed = true; },
    async write(text) {
      const frame = JSON.parse(text);
      state.writes.push(frame);
      if (frame.type === 'result') state.results.push(frame);
      if (frame.type === 'policy-check') {
        state.policyChecks = (state.policyChecks || 0) + 1;
        // The native side waits for this reply; answer off the write stack.
        Promise.resolve().then(() => state.output(JSON.stringify({ type: 'policy', id: frame.id, automatic: state.automatic === true }) + '\n'));
      }
    }
  }; } };
  const bridge = new BrowserBridge(runtime, control, {
    visibleSessionId: () => state.session,
    authorize: async details => { state.requests.push(details); return authorize(details); },
    deliverReady: async info => { state.ready = info; },
    onClosed: () => { state.notifications++; }
  });
  state.bridge = bridge;
  state.send = frame => state.output(JSON.stringify(frame) + '\n');
  return state;
}
async function start(s) { s.bridge.start(); s.send(ready); await tick(); }
async function request(s, id, operation = 'observe', sessionId = 'session1', url) {
  const frame = { type: 'request', id, sessionId, operation };
  if (url !== undefined) frame.url = url;
  s.send(frame);
  for (let i = 0; i < 8; i++) { await tick(); }
}
(async () => {
  // Execute the actual control class separately from ArkUI's declarative syntax.
  const browserSource = fs.readFileSync('entry/src/main/ets/pages/Browser.ets', 'utf8').split('// 独立 Web 实例')[0];
  const browserJs = ts.transpileModule(browserSource, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const browserModule = { exports: {} };
  vm.runInNewContext(browserJs, { module: browserModule, exports: browserModule.exports, require: () => ({}) });
  const control = new browserModule.exports.BrowserControl();
  let currentUrl = 'https://target.test/';
  control.attach(() => true, () => true, () => ({ generation: 0, title: 'T', url: currentUrl }));
  control.setVisible(true);
  assert(control.armRebind(control.currentGeneration()));
  assert.strictEqual(control.rebindPage(), null);
  control.pageEnd(currentUrl); assert.strictEqual(control.rebindPage(), null);
  control.pageBegin(currentUrl); assert.strictEqual(control.rebindPage(), null);
  control.pageEnd('https://old.test/'); assert.strictEqual(control.rebindPage(), null);
  control.pageEnd(currentUrl); assert(control.rebindPage());
  control.pageBegin('https://new.test/');
  control.pageEnd(currentUrl); assert.strictEqual(control.rebindPage(), null, 'older different-URL end is ignored');
  control.navigationChanged(); assert.strictEqual(control.rebindPage(), null);
  control.pageBegin(currentUrl); control.pageEnd(currentUrl); assert(control.rebindPage());
  control.setVisible(false); control.setVisible(true); assert.strictEqual(control.rebindPage(), null);
  assert(control.armRebind(control.currentGeneration()));
  control.pageBegin(currentUrl); control.pageEnd(currentUrl);
  currentUrl = 'about:blank'; assert.strictEqual(control.rebindPage(), null);
  control.consumeRebind(); control.detach();
  const { buildObserveScript } = await import('../plugins/dsh-harmony-browser/observe.js');
  const resource = fs.readFileSync('entry/src/main/ets/pages/BrowserObserveScript.ets', 'utf8');
  const generated = resource.match(/export const BROWSER_OBSERVE_SCRIPT: string = (".*");/);
  assert(generated); assert.strictEqual(JSON.parse(generated[1]), buildObserveScript());
  const { buildClickScriptTemplate, CLICK_INDEX_PLACEHOLDER } = await import('../plugins/dsh-harmony-browser/observe.js');
  const clickTemplate = resource.match(/export const BROWSER_CLICK_SCRIPT_TEMPLATE: string = (".*");/);
  assert(clickTemplate); assert.strictEqual(JSON.parse(clickTemplate[1]), buildClickScriptTemplate());
  const clickPlaceholder = resource.match(/export const BROWSER_CLICK_INDEX_PLACEHOLDER: string = (".*");/);
  assert(clickPlaceholder); assert.strictEqual(JSON.parse(clickPlaceholder[1]), CLICK_INDEX_PLACEHOLDER);
  const text = value => ({ nodeType: 3, nodeValue: value });
  const element = (tag, children = [], attrs = {}, editable = false) => ({
    nodeType: 1, tagName: tag, childNodes: children, isContentEditable: editable,
    getAttribute: key => attrs[key] ?? null, getClientRects: () => [{ width: 10, height: 10 }]
  });
  const body = element('BODY', [text('visible'), element('DIV', [text('editable secret')], { contenteditable: '' }),
    element('DIV', [text('plaintext secret')], { contenteditable: 'plaintext-only' }),
    element('DIV', [text('aria secret')], { role: 'searchbox' }),
    element('DIV', [text('aria secret 2')], { role: 'textbox' }),
    element('DIV', [text('inherited editable secret')], {}, true)]);
  const doc = { title: 'Title', location: { href: 'https://page.test/' }, body };
  const view = { getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }) };
  const observed = JSON.parse(vm.runInNewContext(JSON.parse(generated[1]), { document: doc, window: view }));
  assert.deepStrictEqual(observed.items, [{ type: 'text', text: 'visible' }]);
  let s = setup();
  assert.strictEqual(s.output, undefined, 'must not start implicitly');
  await start(s);
  assert.strictEqual(s.ready.credential, ready.credential);
  await request(s, 'a');
  assert.deepStrictEqual(JSON.parse(s.results[0].value), { untrusted: true, title: 'Title', url: 'https://page.test/', items: [{ type: 'text', text: 'Hello' }] });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(s.requests[0])), { operation: 'observe', sessionId: 'session1', pageTitle: 'Title', pageUrl: 'https://page.test/', targetUrl: '', direction: '', ref: '' });
  await request(s, 'b', 'open', 'session1', 'https://target.test/');
  assert.strictEqual(s.opens.length, 1);
  assert.match(s.results[1].value, /submitted.*not confirmed/i);
  assert.strictEqual(s.requests[1].targetUrl, 'https://target.test/');
  await request(s, 'c');
  assert.strictEqual(s.results[2].ok, false, 'navigation fuses subsequent actions');
  assert.strictEqual(s.bridge.confirmCurrentPage(), false, 'no completed navigation');
  s.rebindReady = true;
  s.session = 'other'; assert.strictEqual(s.bridge.confirmCurrentPage(), false);
  s.session = 'session1'; assert.strictEqual(s.bridge.confirmCurrentPage(), true);
  await request(s, 'd');
  assert.strictEqual(s.results[3].ok, true);
  assert.strictEqual(s.requests.length, 3, 'recovery does not bypass per-request approval');
  assert.strictEqual(s.bridge.confirmCurrentPage(), false, 'confirmation is single-use');
  s.bridge.stop(); assert(s.closed);
  assert.throws(() => s.bridge.start());

  s = setup(); await start(s); await request(s, 'a', 'observe', 'other');
  assert.strictEqual(s.requests.length, 0); assert.strictEqual(s.results[0].ok, false); s.bridge.stop();
  for (const change of ['generation', 'visible', 'session', 'title', 'url', 'stop', 'exit', 'deny']) {
    let resolve;
    s = setup(() => new Promise(r => { resolve = r; })); await start(s);
    s.send({ type: 'request', id: 'a', sessionId: 'session1', operation: 'open', url: 'https://target.test/' });
    await tick();
    if (change === 'generation') s.generation++;
    if (change === 'visible') s.visible = false;
    if (change === 'session') s.session = 'other';
    if (change === 'title') s.title = 'Changed';
    if (change === 'url') s.url = 'https://page.test/spa';
    if (change === 'stop') s.bridge.stop();
    if (change === 'exit') s.exit(1);
    resolve(change !== 'deny'); await tick(); await tick();
    assert.strictEqual(s.opens.length, 0, change);
    if (change !== 'stop' && change !== 'exit') assert.strictEqual(s.results[0].ok, false, change);
    else { assert.strictEqual(s.results.length, 0); assert.strictEqual(s.notifications, 1); }
    s.bridge.stop(); s.bridge.stop();
    assert.strictEqual(s.notifications, 1);
    assert.throws(() => s.bridge.start());
  }
  for (const change of ['generation', 'visible', 'session', 'title', 'url', 'stop', 'exit']) {
    let resolve;
    s = setup(); s.snapshot = () => new Promise(r => { resolve = r; }); await start(s);
    s.send({ type: 'request', id: 'a', sessionId: 'session1', operation: 'observe' });
    await tick(); assert.equal(s.snapshotCalls, 1);
    if (change === 'generation') s.generation++;
    if (change === 'visible') s.visible = false;
    if (change === 'session') s.session = 'other';
    if (change === 'title') s.title = 'Changed';
    if (change === 'url') s.url = 'https://page.test/spa';
    if (change === 'stop') s.bridge.stop();
    if (change === 'exit') s.exit(1);
    resolve(JSON.stringify({ items: [{ type: 'text', text: 'secret' }] })); await tick(); await tick();
    assert.strictEqual(s.results.length, 0, change);
    assert(s.closed, change);
    s.bridge.stop();
  }
  s = setup(); await start(s);
  s.send({ type: 'request', id: 'scroll1', sessionId: 'session1', operation: 'scroll', direction: 'up' });
  await tick(); await tick();
  assert.deepStrictEqual(s.scrolls, ['up']); assert.strictEqual(s.requests[0].direction, 'up');
  assert.match(s.results[0].value, /submitted.*not confirmed/i); s.bridge.stop();
  s = setup(); await start(s);
  assert.strictEqual(await s.bridge.authorize({ id: 'one', sessionId: 'session1', operation: 'scroll', direction: 'up' }), true);
  await assert.rejects(s.bridge.scroll('down')); assert.strictEqual(s.scrolls, undefined); s.bridge.stop();
  s = setup(); await start(s);
  s.bridge.control.scroll = () => { throw Error('native failure'); };
  s.send({ type: 'request', id: 'fail', sessionId: 'session1', operation: 'scroll', direction: 'up' });
  await tick(); await tick(); assert(s.closed); assert.strictEqual(s.results.length, 0); s.bridge.stop();
  for (const change of ['generation', 'visible', 'session', 'title', 'url', 'stop']) {
    let resolve;
    s = setup(() => new Promise(r => { resolve = r; })); await start(s);
    s.send({ type: 'request', id: 'scroll', sessionId: 'session1', operation: 'scroll', direction: 'down' });
    await tick();
    if (change === 'generation') s.generation++;
    if (change === 'visible') s.visible = false;
    if (change === 'session') s.session = 'other';
    if (change === 'title') s.title = 'changed';
    if (change === 'url') s.url = 'https://other.test/';
    if (change === 'stop') s.bridge.stop();
    resolve(true); await tick(); await tick();
    assert.strictEqual(s.scrolls, undefined, change); s.bridge.stop();
  }
  s = setup(); s.url = 'about:blank'; await start(s);
  s.send({ type: 'request', id: 'scroll', sessionId: 'session1', operation: 'scroll', direction: 'down' });
  await tick(); await tick(); assert.strictEqual(s.results[0].ok, false); assert.strictEqual(s.scrolls, undefined); s.bridge.stop();
  s = setup(); s.url = 'about:blank'; await start(s); await request(s, 'a');
  assert.strictEqual(s.snapshotCalls, 0); assert.strictEqual(s.results[0].ok, false);
  await request(s, 'b', 'open', 'session1', 'https://target.test/');
  assert.strictEqual(s.opens.length, 1); s.bridge.stop();
  s = setup(); s.snapshot = async () => JSON.stringify({ items: Array.from({ length: 75 }, () => ({ type: 'text', text: 'x'.repeat(280) })) });
  await start(s); await request(s, 'a');
  const bounded = JSON.parse(s.results[0].value);
  assert.strictEqual(bounded.truncated, true); assert(bounded.items.length < 75);
  assert(s.results[0].value.length <= 16000); s.bridge.stop();
  for (const malformed of ['x'.repeat(150001), JSON.stringify({ items: [{ type: 'text', text: 'x'.repeat(301) }] }), JSON.stringify({ items: [{ type: 'element', tag: 'script' }] })]) {
    s = setup(); s.snapshot = async () => malformed; await start(s); await request(s, 'a');
    assert(s.closed); assert.strictEqual(s.results.length, 0); assert.strictEqual(s.snapshotCalls, 1); s.bridge.stop();
  }
  s = setup(async () => { throw Error('failure'); }); await start(s); await request(s, 'a');
  assert(s.closed); assert.strictEqual(s.results.length, 0); s.bridge.stop();

  // Automatic approval skips only the human dialog. Binding checks, single-use
  // approvals and failure handling stay identical.
  s = setup(); s.automatic = true; await start(s); await request(s, 'a');
  assert.strictEqual(s.requests.length, 0, 'automatic mode must not open the dialog');
  assert.strictEqual(s.policyChecks, 2, 'automatic mode rechecks right before execution');
  assert.strictEqual(s.results[0].ok, true);
  assert.strictEqual(s.snapshotCalls, 1);
  s = setup(); s.automatic = true; await start(s); await request(s, 'a', 'observe', 'other');
  assert.strictEqual(s.requests.length, 0); assert.strictEqual(s.results[0].ok, false, 'session binding still applies');
  s = setup(async () => false); s.automatic = false; await start(s); await request(s, 'a');
  assert.strictEqual(s.requests.length, 1); assert.strictEqual(s.policyChecks, 1);
  assert.strictEqual(s.results[0].ok, false, 'manual denial unchanged');
  console.log('BrowserBridge host simulation passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
