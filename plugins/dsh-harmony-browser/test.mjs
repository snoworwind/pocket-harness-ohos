import { test } from 'node:test';
import assert from 'node:assert/strict';
import { apply, createBrowserCore, registerBrowserTools, validateUrl } from './index.js';

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
test('registration adapter registers four definitions', async () => {
  const defs = []; const session = { id: 'session-a' }; const seen = [];
  const core = createBrowserCore({ authorize: async (r, options) => { seen.push(options.agent); return true; }, execute: async (r, options) => { seen.push(options.agent); return r.operation; } });
  registerBrowserTools({ tools: { register: d => defs.push(d) }, agents: { get: id => id === session.id ? session : undefined } }, d => d, core);
  assert.deepEqual(defs.map(d => d.name), ['browser_open', 'browser_observe', 'browser_scroll', 'browser_click']);
  assert.throws(() => defs[1].execute({}, { signal: new AbortController().signal }), /Session/);
  assert.throws(() => defs[1].execute({}, { agent: { id: 'session-a' } }), /live agent Session/);
  assert.equal(await defs[1].execute({}, { agent: session, signal: new AbortController().signal }), 'observe');
  assert.deepEqual(seen, [session, session]);
});
