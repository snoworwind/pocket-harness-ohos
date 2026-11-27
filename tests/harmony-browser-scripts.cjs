'use strict';
// Executes the fixed page programs against a minimal DOM stand-in.
//
// The other suites assert that scripts contain certain text; this one runs them
// and checks what they actually do to elements: which events fire, in what
// order, whether scrolling happens, and which status word comes back. It still
// cannot prove ArkWeb behaviour (layout, real hit-testing, IME), but it catches
// logic errors that string assertions miss.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const vm = require('node:vm');
const fs = require('node:fs');
const os = require('node:os');

const plugin = path.join(__dirname, '..', 'plugins', 'dsh-harmony-browser');
const load = name => import(path.join(plugin, name));

// --- page stand-ins -------------------------------------------------------

function element(options = {}) {
  const node = {
    isConnected: options.connected !== false,
    disabled: options.disabled === true,
    clicks: 0,
    scrolls: 0,
    dispatched: [],
    rect: options.rect || { left: 10, top: 10, width: 20, height: 20 },
    getClientRects() { return options.box === false ? [] : [{ width: 10, height: 10 }]; },
    getBoundingClientRect() { return this.rect; },
    contains(other) { return other === this; },
    click() { this.clicks++; },
    scrollIntoView() {
      this.scrolls++;
      if (options.onScrollIntoView) options.onScrollIntoView(this);
      else if (options.afterScrollRect) this.rect = options.afterScrollRect;
    },
    dispatchEvent(event) { this.dispatched.push(event.type); return true; }
  };
  return node;
}

class FakeMouseEvent {
  constructor(type, init) { this.type = type; Object.assign(this, init || {}); }
}

function browserContext(refs, options = {}) {
  const context = {
    __phBrowserRefs: refs,
    innerWidth: options.width ?? 800,
    innerHeight: options.height ?? 600,
    getComputedStyle: () => options.style || { display: 'block', visibility: 'visible', opacity: '1' },
    document: { elementFromPoint: () => ('hit' in options ? options.hit : refs[0]) },
    MouseEvent: FakeMouseEvent
  };
  context.window = context;
  return context;
}

function textNode(value) { return { nodeType: 3, nodeValue: value }; }
function domElement(tag, children = [], attrs = {}, style = {}) {
  return {
    nodeType: 1, tagName: tag.toUpperCase(), childNodes: children, hidden: false,
    isContentEditable: false,
    getAttribute(name) { return attrs[name] ?? null; },
    getClientRects() { return [{ width: 10, height: 10 }]; },
    style
  };
}
function textContext(body) {
  const context = {
    document: { body, title: 'T', location: { href: 'https://example.test/' } },
    getComputedStyle: node => ({ display: 'block', visibility: 'visible', opacity: '1', ...node.style })
  };
  context.window = context;
  return context;
}

// --- click: the scroll-into-view path -------------------------------------

test('click scrolls an off-screen element into view, then clicks it', async () => {
  const { buildClickScript } = await load('observe.js');
  const el = element({ rect: { left: 10, top: 5000, width: 20, height: 20 },
    afterScrollRect: { left: 10, top: 100, width: 20, height: 20 } });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([el])), 'clicked');
  assert.equal(el.scrolls, 1, 'the element is brought into view exactly once');
  assert.equal(el.clicks, 1);
});

test('click does not scroll an element that is already on screen', async () => {
  const { buildClickScript } = await load('observe.js');
  const el = element();
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([el])), 'clicked');
  assert.equal(el.scrolls, 0, 'no needless scrolling that could move the page under the user');
  assert.equal(el.clicks, 1);
});

test('click still reports offscreen when scrolling cannot bring the element in', async () => {
  const { buildClickScript } = await load('observe.js');
  const el = element({ rect: { left: 10, top: 5000, width: 20, height: 20 },
    afterScrollRect: { left: 10, top: 4000, width: 20, height: 20 } });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([el])), 'offscreen');
  assert.equal(el.clicks, 0, 'an unreachable element is never clicked');
});

test('click reports covered when another element sits on top after scrolling', async () => {
  const { buildClickScript } = await load('observe.js');
  const el = element({ rect: { left: 10, top: 5000, width: 20, height: 20 },
    afterScrollRect: { left: 10, top: 100, width: 20, height: 20 } });
  const overlay = element();
  const context = browserContext([el], { hit: overlay });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), context), 'covered');
  assert.equal(el.clicks, 0);
});

test('click survives scrollIntoView throwing and stays honest about position', async () => {
  const { buildClickScript } = await load('observe.js');
  const el = element({ rect: { left: 10, top: 5000, width: 20, height: 20 },
    onScrollIntoView: () => { throw new Error('not implemented'); } });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([el])), 'offscreen');
  assert.equal(el.clicks, 0);
});

test('click refuses stale, disabled and hidden targets without scrolling', async () => {
  const { buildClickScript } = await load('observe.js');
  const stale = element({ connected: false });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([stale])), 'stale');
  const disabled = element({ disabled: true });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([disabled])), 'disabled');
  const hidden = element({ box: false });
  assert.equal(vm.runInNewContext(buildClickScript('e0'), browserContext([hidden])), 'hidden');
  const none = element({});
  assert.equal(vm.runInNewContext(buildClickScript('e0'),
    browserContext([none], { style: { display: 'none', visibility: 'visible' } })), 'hidden');
  assert.equal(stale.scrolls + disabled.scrolls + hidden.scrolls + none.scrolls, 0);
});

// --- hover ---------------------------------------------------------------

test('hover dispatches mouseover, mouseenter and mousemove in that order', async () => {
  const { buildHoverScript } = await load('observe.js');
  const el = element();
  assert.equal(vm.runInNewContext(buildHoverScript('e0'), browserContext([el])), 'hovered');
  assert.deepEqual(el.dispatched, ['mouseover', 'mouseenter', 'mousemove']);
});

test('hover never scrolls or clicks the target', async () => {
  const { buildHoverScript } = await load('observe.js');
  const el = element({ rect: { left: 10, top: 5000, width: 20, height: 20 } });
  assert.equal(vm.runInNewContext(buildHoverScript('e0'), browserContext([el])), 'offscreen');
  assert.equal(el.scrolls, 0, 'hover must not move the page');
  assert.equal(el.clicks, 0);
  assert.deepEqual(el.dispatched, []);
});

test('hover fails closed for stale, hidden and covered targets', async () => {
  const { buildHoverScript } = await load('observe.js');
  assert.equal(vm.runInNewContext(buildHoverScript('e0'),
    browserContext([element({ connected: false })])), 'stale');
  assert.equal(vm.runInNewContext(buildHoverScript('e0'),
    browserContext([element({ box: false })])), 'hidden');
  const el = element();
  assert.equal(vm.runInNewContext(buildHoverScript('e0'),
    browserContext([el], { hit: element() })), 'covered');
  assert.deepEqual(el.dispatched, [], 'no synthetic events reach a covered element');
});

// --- text ----------------------------------------------------------------

test('text windows reassemble into the full document without gaps or repeats', async () => {
  const { buildTextScript } = await load('observe.js');
  const body = domElement('body', [textNode('alpha'), textNode('beta'), textNode('gamma'), textNode('delta')]);
  const full = JSON.parse(vm.runInNewContext(buildTextScript(0, 1000), textContext(body)));
  assert.ok(full.total > 0);
  let joined = '';
  for (let offset = 0; offset < full.total; offset += 3) {
    joined += JSON.parse(vm.runInNewContext(buildTextScript(offset, 3), textContext(body))).text;
  }
  assert.equal(joined, full.text, 'paging must not drop or duplicate characters');
});

test('text reports total and truncation, and refuses windows past the end', async () => {
  const { buildTextScript } = await load('observe.js');
  const body = domElement('body', [textNode('x'.repeat(50))]);
  const full = JSON.parse(vm.runInNewContext(buildTextScript(0, 1000), textContext(body)));
  assert.equal(full.total, 51, 'newline-terminated total');
  assert.equal(full.truncated, false);
  const part = JSON.parse(vm.runInNewContext(buildTextScript(0, 10), textContext(body)));
  assert.equal(part.truncated, true);
  assert.equal(part.text.length, 10);
  const past = JSON.parse(vm.runInNewContext(buildTextScript(full.total, 10), textContext(body)));
  assert.equal(past.text, '');
});

test('text excludes hidden, script, style and editable subtrees', async () => {
  const { buildTextScript } = await load('observe.js');
  const editable = domElement('div', [textNode('typed secret')]);
  editable.isContentEditable = true;
  const body = domElement('body', [textNode('visible'), domElement('script', [textNode('script secret')]),
    domElement('style', [textNode('style secret')]), domElement('div', [textNode('hidden secret')], {}, { display: 'none' }),
    domElement('div', [textNode('aria secret')], { 'aria-hidden': 'true' }), editable]);
  const result = JSON.parse(vm.runInNewContext(buildTextScript(0, 1000), textContext(body)));
  assert.equal(result.text.trim(), 'visible');
});

// --- policy matrix ------------------------------------------------------

test('every operation gets the decision its impact and preset imply', async () => {
  const { classifyOperation, OPERATION_IMPACT, BrowserDecision } = await load('policy.js');
  const safe = {
    open: { url: 'https://example.test/' }, observe: {}, text: { offset: 0, limit: 10 },
    scroll: { direction: 'up' }, fill: { ref: 'e0', text: 'YQ==' }, type: { ref: 'e0', text: 'YQ==' },
    select: { ref: 'e0', text: 'YQ==' }, press: { key: 'Enter' }, hover: { ref: 'e0' },
    click: { ref: 'e0' }, navigate: { action: 'back' }
  };
  assert.deepEqual(Object.keys(safe).sort(), Object.keys(OPERATION_IMPACT).sort(),
    'the matrix must cover every operation the policy knows about');
  for (const [operation, args] of Object.entries(safe)) {
    for (const preset of ['', 'read-only', 'workspace-write', 'auto', 'danger-full-access', 'custom']) {
      const { decision, reason } = classifyOperation(operation, args, { preset });
      const impact = OPERATION_IMPACT[operation];
      if (impact === 'read') {
        assert.equal(decision, BrowserDecision.Allow, `${operation}/${preset} is read-only`);
      } else if (preset === 'auto' || preset === 'danger-full-access') {
        assert.equal(decision, BrowserDecision.Allow, `${operation}/${preset} auto-approved`);
      } else {
        assert.equal(decision, BrowserDecision.Prompt, `${operation}/${preset} must ask`);
      }
      assert.equal(typeof reason, 'string');
      assert.ok(reason.length > 0);
    }
  }
});

test('dangerous requests are never silently allowed under any preset', async () => {
  const { classifyOperation, BrowserDecision, OPERATION_IMPACT } = await load('policy.js');
  const dangerous = [
    ['open', { url: 'file:///etc/passwd' }],
    ['open', { url: 'javascript:alert(1)' }],
    ['open', { url: 'data:text/html,x' }],
    ['open', { url: 'https://user:pw@example.test/' }],
    ['open', { url: 'not a url' }],
    ['fill', { ref: 'e0' }],
    ['type', { ref: 'e0', text: '' }],
    ['select', { ref: 'e0' }],
    ['press', {}],
    ['click', { ref: 'e80' }],
    ['click', { ref: 'E1' }],
    ['hover', { ref: 'e1;x' }],
    ['navigate', { action: 'reload' }],
    ['scroll', { direction: 'left' }],
    ['text', { offset: -1, limit: 10 }],
    ['text', { offset: 0, limit: 0 }],
    ['does_not_exist', {}]
  ];
  for (const [operation, args] of dangerous) {
    for (const preset of ['', 'read-only', 'auto']) {
      const { decision } = classifyOperation(operation, args, { preset });
      assert.equal(decision, BrowserDecision.Forbid,
        `${operation} ${JSON.stringify(args)} must be forbidden under ${preset || 'default'}`);
    }
    // An operation the policy does not know at all can never be prompted for:
    // there is no approval dialog that could make it meaningful.
    const known = Object.hasOwn(OPERATION_IMPACT, operation);
    const { decision } = classifyOperation(operation, args, { preset: 'danger-full-access' });
    assert.equal(decision, known ? BrowserDecision.Prompt : BrowserDecision.Forbid,
      `${operation} may only be asked about under full access, never silently allowed`);
  }
});

test('read-only operations are allowed even without a known preset', async () => {
  const { classifyOperation } = await load('policy.js');
  for (const [operation, args] of [['observe', {}], ['text', { offset: 0, limit: 1 }], ['scroll', { direction: 'down' }]]) {
    assert.equal(classifyOperation(operation, args, { preset: '' }).decision, 'allow');
    assert.equal(classifyOperation(operation, args, {}).decision, 'allow');
  }
});

// --- audit --------------------------------------------------------------

test('audit swallows write failures instead of failing the request', async () => {
  const { recordAudit } = await load('audit.js');
  // A regular file where the audit directory should be makes mkdir fail fast
  // (ENOTDIR) without depending on filesystem quirks like /proc.
  const blocker = path.join(os.tmpdir(), `browser-audit-blocker-${process.pid}`);
  fs.writeFileSync(blocker, 'not a directory');
  const prior = process.env.DSH_HOME;
  process.env.DSH_HOME = blocker;
  try {
    assert.doesNotThrow(() => recordAudit({ operation: 'observe', outcome: 'ok' }));
  } finally {
    if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior;
    fs.rmSync(blocker, { force: true });
  }
});

test('audit truncates oversized fields and keeps one line per call', async () => {
  const { recordAudit, auditFile } = await load('audit.js');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-audit-bound-'));
  const prior = process.env.DSH_HOME;
  process.env.DSH_HOME = dir;
  try {
    recordAudit({ operation: 'click', decision: 'prompt', reason: 'r'.repeat(1000), outcome: 'ok' });
    for (let i = 0; i < 200; i++) recordAudit({ operation: 'observe', outcome: 'ok' });
    const lines = fs.readFileSync(auditFile(), 'utf8').trim().split('\n');
    assert.equal(lines.length, 201, 'concurrent-ish writes never interleave lines');
    const first = JSON.parse(lines[0]);
    assert.equal(first.reason.length, 200, 'oversized fields are truncated, not dropped or unbounded');
    assert.ok(lines.every(line => line.startsWith('{')));
  } finally {
    if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('audit file is created with owner-only permissions', async () => {
  const { recordAudit, auditFile } = await load('audit.js');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-audit-mode-'));
  const prior = process.env.DSH_HOME;
  process.env.DSH_HOME = dir;
  try {
    recordAudit({ operation: 'open', outcome: 'ok' });
    const mode = fs.statSync(auditFile()).mode & 0o777;
    assert.equal(mode, 0o600, 'audit trail must not be world-readable');
  } finally {
    if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- snapshot reference bounds -------------------------------------------

test('snapshot never allocates more than 80 references', async () => {
  const { observePage } = await load('observe.js');
  const buttons = Array.from({ length: 100 }, () => domElement('button', [textNode('go')]));
  const body = domElement('body', buttons);
  const doc = { title: 't', location: { href: 'https://example.test/' }, body };
  const refs = [];
  const result = observePage(doc, textContext(body).window, () => {
    const ref = 'e' + refs.length;
    refs.push(ref);
    return ref;
  });
  assert.ok(refs.length <= 80, 'the page-side array must stay bounded');
  assert.equal(refs[0], 'e0');
  assert.equal(refs[refs.length - 1], 'e' + (refs.length - 1));
  const tagged = result.items.filter(item => item.ref);
  assert.equal(tagged.length, refs.length, 'every allocated reference appears in the snapshot');
  assert.equal(result.truncated, true, 'hitting the reference bound is reported, not hidden');
});

test('validateRef accepts exactly e0..e79 and rejects everything else', async () => {
  const { validateRef } = await load('observe.js');
  assert.equal(validateRef('e0'), 0);
  assert.equal(validateRef('e79'), 79);
  for (const bad of ['e80', 'e999', 'E1', 'e01a', 'e1;x', '', 'e', 7, null, ' e1']) {
    assert.throws(() => validateRef(bad), /Invalid element reference/, 'rejects ' + JSON.stringify(bad));
  }
});

test('a truncated snapshot keeps references consistent with what it returned', async () => {
  const { observePage } = await load('observe.js');
  const links = Array.from({ length: 120 }, (_, i) => domElement('a', [textNode('link' + i)]));
  const body = domElement('body', links);
  const doc = { title: 't', location: { href: 'https://example.test/' }, body };
  const refs = [];
  const result = observePage(doc, textContext(body).window, () => {
    const ref = 'e' + refs.length;
    refs.push(ref);
    return ref;
  });
  assert.equal(result.truncated, true);
  const seen = new Set(result.items.filter(i => i.ref).map(i => i.ref));
  for (const ref of seen) assert.ok(refs.includes(ref), 'no item points at an unallocated reference');
  assert.equal(seen.size, refs.length);
});

// --- untrusted-output rendering ------------------------------------------

test('rendered page output is bounded, randomised and never splits a surrogate pair', async () => {
  const { renderUntrustedBrowserResult } = await load('index.js');
  const first = renderUntrustedBrowserResult('x'.repeat(100));
  const second = renderUntrustedBrowserResult('x'.repeat(100));
  assert.notEqual(first, second, 'boundaries are randomised per call');
  assert.match(first, /UNTRUSTED/);

  const emoji = '\u{1F600}'.repeat(10);
  const cut = renderUntrustedBrowserResult(emoji, 5);
  assert.ok(!cut.includes('\uFFFD'), 'a truncated surrogate pair must not produce a replacement char');
  assert.ok(cut.length > 0);

  assert.throws(() => renderUntrustedBrowserResult(42), TypeError);
  assert.throws(() => renderUntrustedBrowserResult('x', 0), RangeError);
  assert.throws(() => renderUntrustedBrowserResult('x', 65537), RangeError);
});
