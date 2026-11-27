'use strict';
// Behavioural tests for the fixed page programs (fill/type/press/select/click).
// They run in Node's vm with a simulated DOM, NOT in ArkWeb: device behaviour
// remains unverified and is tracked in docs/VALIDATION.md.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const vm = require('node:vm');

const plugin = path.join(__dirname, '../plugins/dsh-harmony-browser');
const load = () => import(path.join(plugin, 'observe.js'));

function makeContext(refs, extra = {}) {
  const listeners = [];
  class FakeEvent {
    constructor(type, options = {}) { this.type = type; Object.assign(this, options); }
  }
  const context = {
    __phBrowserRefs: refs,
    atob: (b64) => Buffer.from(b64, 'base64').toString('latin1'),
    TextDecoder, Uint8Array,
    Event: FakeEvent,
    KeyboardEvent: FakeEvent,
    innerWidth: 800, innerHeight: 600,
    listeners,
    ...extra
  };
  return context;
}

function inputElement(tag = 'INPUT', extra = {}) {
  const el = {
    tagName: tag,
    isConnected: true,
    disabled: false,
    readOnly: false,
    type: 'text',
    value: '',
    events: [],
    focused: false,
    focus() { this.focused = true; },
    dispatchEvent(event) { this.events.push(event.type); return true; },
    getClientRects() { return [{ width: 10, height: 10 }]; },
    getBoundingClientRect() { return { left: 10, top: 10, width: 20, height: 20 }; },
    contains() { return false; }
  };
  return Object.assign(el, extra);
}

test('fill clears then writes through the native setter and fires input/change', async () => {
  const { buildInputScript, encodeText } = await load();
  const el = inputElement();
  const context = makeContext([el]);
  // Controlled-component path: the prototype setter is what frameworks track.
  context.HTMLInputElement = { prototype: {} };
  let setterCalls = [];
  Object.defineProperty(context.HTMLInputElement.prototype, 'value', {
    set(value) { setterCalls.push(value); this._value = value; },
    get() { return this._value || ''; }
  });
  delete el.value; // let the prototype accessor drive reads, as on a real element
  Object.setPrototypeOf(el, context.HTMLInputElement.prototype);
  const script = buildInputScript('e0', encodeText('hello 世界'), 'fill');
  const status = vm.runInNewContext(script, context);
  assert.equal(status, 'filled');
  assert.deepEqual(setterCalls, ['', 'hello 世界'], 'fill clears first, then writes');
  assert.deepEqual(el.events, ['input', 'input', 'change']);
  assert.equal(el.focused, true);
});

test('type appends without clearing; fill replaces an existing value', async () => {
  const { buildInputScript, encodeText } = await load();
  const el = inputElement('TEXTAREA', { value: 'old' });
  const context = makeContext([el]);
  context.HTMLTextAreaElement = { prototype: {} };
  assert.equal(vm.runInNewContext(buildInputScript('e0', encodeText('+new'), 'type'), context), 'typed');
  assert.equal(el.value, 'old+new');
  assert.equal(vm.runInNewContext(buildInputScript('e0', encodeText('reset'), 'fill'), context), 'filled');
  assert.equal(el.value, 'reset');
});

test('input refuses non-editable, read-only, disabled and stale targets', async () => {
  const { buildInputScript, encodeText } = await load();
  const text = encodeText('x');
  const cases = [
    [inputElement('INPUT', { type: 'checkbox' }), 'not_editable'],
    [inputElement('INPUT', { type: 'date' }), 'not_editable'],
    [inputElement('INPUT', { type: 'range' }), 'not_editable'],
    [inputElement('BUTTON'), 'not_editable'],
    [inputElement('SELECT'), 'not_editable'],
    [inputElement('INPUT', { readOnly: true }), 'readonly'],
    [inputElement('INPUT', { disabled: true }), 'disabled'],
    [inputElement('INPUT', { isConnected: false }), 'stale']
  ];
  for (const [el, expected] of cases) {
    const status = vm.runInNewContext(buildInputScript('e0', text, 'fill'), makeContext([el]));
    assert.equal(status, expected, `${el.tagName}/${el.type} should be ${expected}`);
    assert.equal(el.events.length, 0, 'a refused field must not receive events');
  }
  assert.equal(vm.runInNewContext(buildInputScript('e0', text, 'fill'), makeContext([])), 'stale');
});

test('input reports page rewrites and truncation without echoing the value', async () => {
  const { buildInputScript, encodeText } = await load();
  const secret = 'super-secret-value';
  // Page rewrites the field (input mask) after entry.
  const rewriting = inputElement();
  const context = makeContext([rewriting]);
  context.HTMLInputElement = { prototype: {} };
  Object.defineProperty(context.HTMLInputElement.prototype, 'value', {
    set(value) { this._value = value.replace(/[a-z]/g, '#'); },
    get() { return this._value || ''; }
  });
  delete rewriting.value;
  Object.setPrototypeOf(rewriting, context.HTMLInputElement.prototype);
  const status = vm.runInNewContext(buildInputScript('e0', encodeText(secret), 'fill'), context);
  assert.equal(status, 'rewritten');
  assert.ok(!status.includes(secret), 'status must never contain field content');

  // A truncating field (maxlength-like behaviour) keeps a prefix.
  const truncating = inputElement();
  const ctx2 = makeContext([truncating]);
  ctx2.HTMLInputElement = { prototype: {} };
  Object.defineProperty(ctx2.HTMLInputElement.prototype, 'value', {
    set(value) { this._value = value.slice(0, 3); },
    get() { return this._value || ''; }
  });
  delete truncating.value;
  Object.setPrototypeOf(truncating, ctx2.HTMLInputElement.prototype);
  assert.equal(vm.runInNewContext(buildInputScript('e0', encodeText('abcdef'), 'fill'), ctx2), 'truncated');
});

test('text encoding rejects control characters, oversized text and bad base64', async () => {
  const { encodeText, buildInputScript, MAX_TEXT } = await load();
  assert.throws(() => encodeText('a\u0000b'), /control characters/);
  assert.throws(() => encodeText('a'.repeat(MAX_TEXT + 1)), /too long/);
  assert.equal(encodeText('line1\nline2\tend').length > 0, true, 'newline and tab stay allowed');
  assert.throws(() => buildInputScript('e0', 'aGVsbG8=";alert(1)//', 'fill'), /Invalid encoded text/);
  assert.throws(() => buildInputScript('e0', encodeText('x'), 'eval'), /Invalid input mode/);
  // A script shaped by an attacker must never appear in the source.
  const source = buildInputScript('e0', encodeText('";alert(1);//'), 'fill');
  assert.ok(!source.includes('";alert(1);//'), 'text is base64, not source');
  assert.match(source, /atob\("[A-Za-z0-9+/=]*"\)/);
});

test('press dispatches keydown/keypress/keyup to the focused element', async () => {
  const { buildPressScript } = await load();
  const el = inputElement();
  const seen = [];
  el.dispatchEvent = (event) => { seen.push(event.type + ':' + event.key); return true; };
  const context = makeContext([], { document: { activeElement: el } });
  assert.equal(vm.runInNewContext(buildPressScript('Enter'), context), 'pressed');
  assert.deepEqual(seen, ['keydown:Enter', 'keypress:Enter', 'keyup:Enter']);
  assert.equal(vm.runInNewContext(buildPressScript('Tab'), makeContext([], { document: { activeElement: null } })), 'no_focus');
  assert.throws(() => buildPressScript('F12'), /Unsupported key/);
  assert.throws(() => buildPressScript('Enter";alert(1)//'), /Unsupported key/);
});

test('Enter requests form submission only when a form is present', async () => {
  const { buildPressScript } = await load();
  let submitted = 0;
  const form = { requestSubmit() { submitted++; } };
  const el = inputElement('INPUT', { form });
  const context = makeContext([], { document: { activeElement: el } });
  assert.equal(vm.runInNewContext(buildPressScript('Enter'), context), 'submitted');
  assert.equal(submitted, 1);
  const noForm = inputElement('INPUT', { form: null, closest: () => null });
  const ctx2 = makeContext([], { document: { activeElement: noForm } });
  assert.equal(vm.runInNewContext(buildPressScript('Enter'), ctx2), 'pressed');
});

test('select matches by value or exact label and detects ambiguity', async () => {
  const { buildSelectScript, encodeText } = await load();
  const makeSelect = (options) => inputElement('SELECT', {
    options: options.map(([value, label]) => ({ value, label, text: label, disabled: false })),
    selectedIndex: -1
  });
  const select = makeSelect([['cn', 'China'], ['us', 'United States']]);
  const context = makeContext([select]);
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('us'), ''), context), 'selected');
  assert.equal(select.selectedIndex, 1);
  assert.deepEqual(select.events, ['input', 'change']);
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('China'), ''), context), 'selected');
  assert.equal(select.selectedIndex, 0);
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('zz'), ''), context), 'option_not_found');
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('x'), ''), makeContext([inputElement('INPUT')])), 'not_select');
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('x'), ''), makeContext([inputElement('SELECT', { disabled: true, options: [] })])), 'disabled');

  // Same string is one option's value and another's label -> ambiguous.
  const ambiguous = makeSelect([['a', 'b'], ['c', 'a']]);
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('a'), ''), makeContext([ambiguous])), 'ambiguous');
  // Two options sharing one label -> ambiguous.
  const shared = makeSelect([['1', 'Same'], ['2', 'Same']]);
  assert.equal(vm.runInNewContext(buildSelectScript('e0', encodeText('Same'), ''), makeContext([shared])), 'ambiguous');
});

test('click fails when covered or offscreen instead of reporting success', async () => {
  const { buildClickScript } = await load();
  const el = inputElement('BUTTON');
  el.clicks = 0;
  el.click = () => { el.clicks++; };
  // Covered by a consent banner.
  const banner = { contains: () => false };
  const covered = makeContext([el], { document: { elementFromPoint: () => banner } });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), covered), 'covered');
  assert.equal(el.clicks, 0, 'a covered element must not be clicked');

  // Outside the viewport.
  const offscreen = inputElement('BUTTON', { getBoundingClientRect: () => ({ left: 5000, top: 10, width: 20, height: 20 }) });
  offscreen.click = () => { throw new Error('must not click'); };
  const ctx2 = makeContext([offscreen], { document: { elementFromPoint: () => offscreen } });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), ctx2), 'offscreen');

  // Clicking a child inside the target is fine.
  const child = { contains: () => false };
  el.contains = (node) => node === child;
  const ctx3 = makeContext([el], { document: { elementFromPoint: () => child } });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), ctx3), 'clicked');
  assert.equal(el.clicks, 1);
});

test('snapshot exposes captions for links and buttons but never input values', async () => {
  const { observePage } = await load();
  const element = (tag, caption) => ({
    nodeType: 1, tagName: tag, hidden: false, isContentEditable: false,
    textContent: caption,
    getAttribute: () => null,
    getClientRects: () => [{ width: 5, height: 5 }],
    childNodes: []
  });
  const button = element('BUTTON', '  Sign   in ');
  const input = element('INPUT', 'typed secret');
  const body = element('BODY', '');
  body.childNodes = [button, input];
  const doc = { title: '', location: { href: 'https://example.test/' }, body };
  const view = { getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }) };
  const result = observePage(doc, view, () => 'e0');
  const items = result.items.filter(item => item.type === 'element');
  assert.equal(items[0].caption, 'Sign in');
  assert.equal(items[1].caption, undefined, 'inputs never expose their value');
});
