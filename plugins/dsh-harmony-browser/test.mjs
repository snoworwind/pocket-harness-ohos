import { test } from 'node:test';
import assert from 'node:assert/strict';
import { apply, createBrowserCore, registerBrowserTools, validateUrl } from './index.js';
import { BrowserDecision, classifyOperation, detectDanger } from './policy.js';

test('plugin is inert and URL validation fails closed', () => {
  apply({ tools: { register() { throw Error('unexpected registration'); } } });
  for (const url of ['file:///tmp/x', 'javascript:alert(1)', 'http://a:b@example.com/', 'https://example.com/\n']) assert.throws(() => validateUrl(url));
  assert.equal(validateUrl('https://example.com'), 'https://example.com/');
});
test('serial execution, explicit approval and bounded queue', async () => {
  let release; const gate = new Promise(r => { release = r; }); const events = [];
  const core = createBrowserCore({ authorize: async r => { events.push('authorize ' + r.operation); return true; }, execute: async r => { events.push('execute ' + r.operation); if (r.operation === 'open') await gate; return 'ok'; } }, { maxPending: 2 });
  const a = core.request('open', { url: 'https://example.com' });
  const b = core.request('observe');
  await assert.rejects(core.request('observe'), /full/);
  release(); assert.equal(await a, 'ok'); assert.equal(await b, 'ok');
  assert.deepEqual(events, ['authorize open', 'execute open', 'authorize observe', 'execute observe']);
  core.close(); await assert.rejects(core.request('observe'), /closed/);
});
test('denial, input bounds and response bounds', async () => {
  let executed = 0;
  const denied = createBrowserCore({ authorize: async () => false, execute: async () => { executed++; } });
  await assert.rejects(denied.request('observe'), /denied/); assert.equal(executed, 0);
  await assert.rejects(denied.request('observe', { url: 'x' }), /arguments/);
  const big = createBrowserCore({ authorize: async () => true, execute: async () => 'x'.repeat(65537) });
  await assert.rejects(big.request('observe'), /oversized/);
});
test('active cancellation closes bridge, queued request never executes', async () => {
  let executed = 0;
  const core = createBrowserCore({ authorize: async () => true, execute: async () => { executed++; return new Promise(() => {}); } });
  const controller = new AbortController();
  const a = core.request('observe', {}, { signal: controller.signal });
  const b = core.request('observe'); await Promise.resolve(); controller.abort();
  await assert.rejects(a, /aborted/); await assert.rejects(b, /closed/);
  await assert.rejects(core.request('observe'), /closed/); assert.equal(executed, 1);
});
test('registration adapter registers nine definitions', async () => {
  const defs = []; const session = { id: 'session-a' }; const seen = [];
  const core = createBrowserCore({ authorize: async (r, options) => { seen.push(options.agent); return true; }, execute: async (r, options) => { seen.push(options.agent); return r.operation; } });
  registerBrowserTools({ tools: { register: d => defs.push(d) }, agents: { get: id => id === session.id ? session : undefined } }, d => d, core);
  assert.deepEqual(defs.map(d => d.name), ['browser_open', 'browser_observe', 'browser_scroll', 'browser_click', 'browser_hover', 'browser_fill', 'browser_type', 'browser_press', 'browser_select', 'browser_navigate']);
  assert.throws(() => defs[1].execute({}, { signal: new AbortController().signal }), /Session/);
  assert.throws(() => defs[1].execute({}, { agent: { id: 'session-a' } }), /live agent Session/);
  assert.equal(await defs[1].execute({}, { agent: session, signal: new AbortController().signal }), 'observe');
  assert.deepEqual(seen, [session, session]);
});

// Codex-derived invariant: a dangerous request is never silently allowed.
// danger-full-access may only downgrade Forbid to Prompt, never to Allow.
test('policy: danger is never silently allowed under any preset', () => {
  for (const url of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,<b>x', 'http://user:pass@example.com/']) {
    assert.equal(classifyOperation('open', { url }, { preset: 'danger-full-access' }).decision, BrowserDecision.Prompt);
    for (const preset of ['', 'read-only', 'workspace-write', 'auto', 'custom']) {
      assert.equal(classifyOperation('open', { url }, { preset }).decision, BrowserDecision.Forbid);
    }
  }
});
test('policy: reads are allowed, mutations and external actions are prompted', () => {
  assert.equal(classifyOperation('observe', {}, {}).decision, BrowserDecision.Allow);
  assert.equal(classifyOperation('scroll', { direction: 'down' }, {}).decision, BrowserDecision.Allow);
  for (const [op, req] of [['fill', { ref: 'e1', text: 'aGk=' }], ['type', { ref: 'e1', text: 'aGk=' }], ['select', { ref: 'e1', text: 'aGk=' }], ['click', { ref: 'e1' }], ['press', { key: 'Enter' }], ['navigate', { action: 'refresh' }]]) {
    assert.equal(classifyOperation(op, req, {}).decision, BrowserDecision.Prompt);
  }
  assert.equal(classifyOperation('click', { ref: 'e1' }, { preset: 'auto' }).decision, BrowserDecision.Allow);
});
test('policy: rejections carry a concrete reason, malformed requests fail closed', () => {
  const r = classifyOperation('open', { url: 'file:///etc/passwd' }, { preset: 'auto' });
  assert.equal(r.decision, BrowserDecision.Forbid);
  assert.match(r.reason, /file:/);
  assert.match(classifyOperation('wat', {}, {}).reason, /unsupported/);
  assert.equal(detectDanger('observe', {}), null);
  assert.match(detectDanger('click', { ref: 'zz' }), /reference/);
  assert.match(detectDanger('fill', { ref: 'e1' }), /encoded text/);
  assert.match(detectDanger('press', {}), /key/);
});
