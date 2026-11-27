'use strict';
// Element-reference and click-program tests. These exercise the pure host-side
// pieces (reference allocation, fixed click program, ArkTS BrowserControl
// guards) and do NOT verify ArkWeb or device behaviour.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const plugin = path.join(root, 'plugins/dsh-harmony-browser');
const rawfile = path.join(root, 'entry/src/main/resources/rawfile/tools/harmony-browser');

async function loadObserve() { return import(path.join(plugin, 'observe.js')); }

function fakeElement({ connected = true, disabled = false, box = true, display = 'block', visibility = 'visible' } = {}) {
  const el = {
    isConnected: connected,
    disabled,
    clicks: 0,
    click() { this.clicks++; },
    getClientRects() { return box ? [{ width: 10, height: 10 }] : []; },
    getBoundingClientRect() { return box ? { left: 10, top: 10, width: 20, height: 20 } : { left: 0, top: 0, width: 0, height: 0 }; },
    contains() { return false; }
  };
  return el;
}

function runClick(script, refs, style) {
  const context = { __phBrowserRefs: refs, innerWidth: 800, innerHeight: 600 };
  context.getComputedStyle = () => (style || { display: 'block', visibility: 'visible' });
  // Default: the element itself is the hit target, i.e. nothing covers it.
  context.document = { elementFromPoint: () => refs[0] };
  return vm.runInNewContext(script, context);
}

test('snapshot allocates refs only for interactive, boxed elements', async () => {
  const { observePage } = await loadObserve();
  const make = (tag, extra = {}) => Object.assign({
    nodeType: 1, tagName: tag, hidden: false, isContentEditable: false,
    getAttribute: () => null,
    getClientRects: () => [{ width: 5, height: 5 }],
    childNodes: []
  }, extra);
  const anchor = make('A');
  const paragraph = make('P');
  const invisibleButton = make('BUTTON', { getClientRects: () => [] });
  const body = make('BODY', { childNodes: [anchor, paragraph, invisibleButton] });
  const doc = { title: 't', location: { href: 'https://example.test/' }, body };
  const view = { getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }) };
  const registered = [];
  const result = observePage(doc, view, (node) => { const ref = 'e' + registered.length; registered.push(node); return ref; });
  assert.deepEqual(registered, [anchor]);
  const elements = result.items.filter(item => item.type === 'element');
  assert.equal(elements.length, 1);
  assert.equal(elements[0].ref, 'e0');
  assert.equal(elements[0].tag, 'a');
  // Without a register callback the snapshot stays ref-free.
  const plain = observePage(doc, view);
  assert.equal(plain.items.filter(item => item.type === 'element').every(item => item.ref === undefined), true);
});

test('a throwing or junk register callback never breaks the snapshot', async () => {
  const { observePage } = await loadObserve();
  const anchor = { nodeType: 1, tagName: 'A', hidden: false, isContentEditable: false,
    getAttribute: () => null, getClientRects: () => [{ width: 5, height: 5 }], childNodes: [] };
  const body = { nodeType: 1, tagName: 'BODY', hidden: false, isContentEditable: false,
    getAttribute: () => null, getClientRects: () => [{ width: 5, height: 5 }], childNodes: [anchor] };
  const doc = { title: '', location: { href: 'https://example.test/' }, body };
  const view = { getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }) };
  const junk = observePage(doc, view, () => 'not-a-ref');
  assert.equal(junk.items.find(item => item.type === 'element').ref, undefined);
  const thrown = observePage(doc, view, () => { throw new Error('boom'); });
  assert.equal(thrown.items.find(item => item.type === 'element').ref, undefined);
});

test('click program is fixed and rejects every non-canonical reference', async () => {
  const { buildClickScript, buildClickScriptTemplate, CLICK_INDEX_PLACEHOLDER } = await loadObserve();
  for (const bad of ['', 'e', 'E1', 'e01a', 'e1;alert(1)', 'e-1', 'e1 ', ' e1', 'e80', 'e999', 'e1\n', null, 1, {}]) {
    assert.throws(() => buildClickScript(bad), /Invalid element reference/, `should reject ${String(bad)}`);
  }
  assert.ok(buildClickScript('e0').includes('[0]'));
  assert.ok(buildClickScript('e79').includes('[79]'));
  // The template carries the placeholder; substituting a non-integer is the
  // caller's bug, so the template itself must contain no digits-as-index.
  const template = buildClickScriptTemplate();
  assert.ok(template.includes(CLICK_INDEX_PLACEHOLDER));
  assert.equal(template.includes('__phBrowserRefs'), true);
});

test('click program dispatches once and reports only fixed status words', async () => {
  const { buildClickScript } = await loadObserve();
  const el = fakeElement();
  assert.equal(runClick(buildClickScript('e0'), [el]), 'clicked');
  assert.equal(el.clicks, 1);

  assert.equal(runClick(buildClickScript('e0'), []), 'stale');
  assert.equal(runClick(buildClickScript('e0'), [fakeElement({ connected: false })]), 'stale');
  assert.equal(runClick(buildClickScript('e1'), [el]), 'stale');
  assert.equal(runClick(buildClickScript('e0'), [fakeElement({ disabled: true })]), 'disabled');
  assert.equal(runClick(buildClickScript('e0'), [fakeElement({ box: false })]), 'hidden');
  assert.equal(runClick(buildClickScript('e0'), [el], { display: 'none', visibility: 'visible' }), 'hidden');
  assert.equal(runClick(buildClickScript('e0'), [el], { display: 'block', visibility: 'hidden' }), 'hidden');
  // A missing or poisoned reference store fails closed rather than throwing.
  assert.equal(vm.runInNewContext(buildClickScript('e0'), {}), 'stale');
  assert.equal(vm.runInNewContext(buildClickScript('e0'), { __phBrowserRefs: null }), 'stale');
});

test('observe script wires the reference store and stays self-contained', async () => {
  const { buildObserveScript, REFS_KEY } = await loadObserve();
  const script = buildObserveScript();
  assert.ok(script.includes(REFS_KEY));
  assert.ok(script.includes('observePage(document,window,register)'));
  // Running it against a hostile-but-minimal document must not throw.
  const doc = {
    title: 'x', location: { href: 'https://example.test/' },
    body: { nodeType: 1, tagName: 'BODY', hidden: false, isContentEditable: false,
      getAttribute: () => null, getClientRects: () => [{ width: 1, height: 1 }], childNodes: [] }
  };
  const context = { document: doc, window: { getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }) } };
  const parsed = JSON.parse(vm.runInNewContext(script, context));
  assert.equal(parsed.url, 'https://example.test/');
  assert.equal(Array.isArray(context[REFS_KEY]), true);
});

test('ArkTS BrowserControl guards click by generation and reference', async () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Browser.ets'), 'utf8');
  const begin = source.indexOf('export interface BrowserObservation');
  const end = source.indexOf('// 独立 Web 实例');
  assert.ok(begin >= 0 && end > begin);
  const js = ts.transpileModule(source.slice(begin, end),
    { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const sandbox = { exports: {} };
  vm.runInNewContext(js, sandbox);
  const { BrowserControl } = sandbox.exports;

  const seen = [];
  const control = new BrowserControl();
  control.attach(() => true, () => true, () => ({ generation: 0, title: 't', url: 'https://example.test/' }),
    async () => '', () => {}, async (ref) => { seen.push(ref); return 'clicked'; });
  control.setVisible(true);
  const generation = control.currentGeneration();
  assert.equal(await control.click(generation, 'e3'), 'clicked');
  assert.deepEqual(seen, ['e3']);
  for (const bad of ['', 'e', 'E1', 'e1;x', 'e80', 'e999', null, 5]) {
    await assert.rejects(() => control.click(generation, bad), /Invalid element reference/, `should reject ${String(bad)}`);
  }
  assert.deepEqual(seen, ['e3']);
  control.pageBegin('https://other.test/');
  await assert.rejects(() => control.click(generation, 'e3'), /Browser binding changed/);
  assert.deepEqual(seen, ['e3']);
});

test('ArkTS action status decoding accepts only fixed words', () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/platform/BrowserBridge.ets'), 'utf8');
  const begin = source.indexOf('export function isValidRef');
  assert.ok(begin >= 0);
  const js = ts.transpileModule(source.slice(begin),
    { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const sandbox = { exports: {} };
  const scriptsSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/BrowserObserveScript.ets'), 'utf8');
  sandbox.BROWSER_ACTION_STATUSES = JSON.parse(scriptsSource.match(/export const BROWSER_ACTION_STATUSES: string\[\] = (\[[^\]]*\]);/)[1]);
  vm.runInNewContext(js, sandbox);
  const { isValidRef, decodeActionStatus } = sandbox.exports;
  assert.equal(isValidRef('e0'), true);
  assert.equal(isValidRef('e79'), true);
  assert.equal(isValidRef('e80'), false);
  assert.equal(isValidRef('E0'), false);
  assert.equal(isValidRef('e0 '), false);
  assert.equal(decodeActionStatus('clicked'), 'clicked');
  assert.equal(decodeActionStatus('"clicked"'), 'clicked');
  assert.equal(decodeActionStatus('stale'), 'stale');
  assert.equal(decodeActionStatus('"<script>"'), 'invalid');
  assert.equal(decodeActionStatus('x'.repeat(65)), 'invalid');
  assert.equal(decodeActionStatus(null), 'invalid');
});

test('relay and bridge sources carry the click operation at every layer', () => {
  const relay = fs.readFileSync(path.join(root, 'entry/src/main/ets/platform/BrowserRelay.ets'), 'utf8');
  const bridge = fs.readFileSync(path.join(root, 'entry/src/main/ets/platform/BrowserBridge.ets'), 'utf8');
  const client = fs.readFileSync(path.join(plugin, 'client-relay.js'), 'utf8');
  const server = fs.readFileSync(path.join(plugin, 'relay.cjs'), 'utf8');
  const index = fs.readFileSync(path.join(plugin, 'index.js'), 'utf8');
  for (const text of [relay, bridge]) assert.match(text, /click/);
  assert.match(relay, /frame\.operation === 'click'/);
  assert.match(bridge, /signatureOf\('click'/);
  assert.match(client, /operation === 'click'/);
  assert.match(server, /obj\.operation === 'click'/);
  assert.match(index, /name: 'browser_click'/);
});

test('rawfile plugin copies stay byte-identical to the plugin sources', () => {
  for (const file of ['index.js', 'client-relay.js', 'relay.cjs', 'credential-provider.js']) {
    const a = fs.readFileSync(path.join(plugin, file));
    const b = fs.readFileSync(path.join(rawfile, file));
    assert.equal(a.equals(b), true, `${file} drifted from plugins/`);
  }
});
