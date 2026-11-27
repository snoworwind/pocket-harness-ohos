'use strict';
// Simulation of the native relay adapter; no OHOS or ArkWeb APIs are exercised.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/platform/BrowserRelay.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const scriptsSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/BrowserObserveScript.ets'), 'utf8');
const allowedKeys = JSON.parse(scriptsSource.match(/export const BROWSER_ALLOWED_KEYS: string\[\] = (\[[^\]]*\]);/)[1]);
const sandbox = { exports: {}, Date, JSON, Object, Array, Number, String, Error, Promise, Set, URL,
  setTimeout, clearTimeout, require: name => {
    if (name === '@kit.ArkTS') return { url: { URL } };
    if (name === '../pages/BrowserObserveScript') return { BROWSER_ALLOWED_KEYS: allowedKeys };
    throw Error('unexpected module ' + name);
  } };
vm.runInNewContext(js, sandbox);
const { BrowserRelay } = sandbox.exports;
const tick = () => new Promise(resolve => setImmediate(resolve));
// `automatic` mirrors the trusted permission answer the DSH client would give.
function setup(approve = async () => true, automatic = false, holdPolicy = false) {
  let output, closed = 0, ready; const writes = [];
  let authorization, authorizationAutomatic; const heldReplies = [];
  const relay = new BrowserRelay((onOutput) => {
    output = onOutput;
    return {
      async write(text) {
        const frame = JSON.parse(text);
        writes.push(frame);
        if (frame.type === 'policy-check') {
          const reply = () => output(JSON.stringify({ type: 'policy', id: frame.id, automatic: automatic }) + '\n');
          if (holdPolicy) heldReplies.push(reply); else Promise.resolve().then(reply);
        }
      },
      close: () => { closed++; }
    };
  }, {
    deliverReady: async info => { ready = info; },
    authorize: async (request, isAutomatic) => { authorization = request; authorizationAutomatic = isAutomatic; return approve(request); },
    open: async target => 'opened:' + target,
    observe: async () => 'observed',
    scroll: async direction => 'submitted:' + direction
  });
  const send = frame => output(typeof frame === 'string' ? frame : JSON.stringify(frame) + '\n');
  return { relay, send, writes,
    results: () => writes.filter(frame => frame.type === 'result'),
    checks: () => writes.filter(frame => frame.type === 'policy-check'),
    get closed() { return closed; }, get authorization() { return authorization; }, heldReplies,
    get automatic() { return authorizationAutomatic; }, get ready() { return ready; } };
}
const ready = { type: 'ready', version: 1, host: '127.0.0.1', port: 1234, credential: 'a'.repeat(64) };
async function settle(state) { for (let i = 0; i < 6; i++) { await tick(); } }
test('native adapter authorizes session-labelled requests before execution', async t => {
  const state = setup(); t.after(() => state.relay.close()); state.send(ready); await tick();
  assert.equal(state.ready.port, 1234);
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'open', url: 'https://example.test/' });
  await settle(state);
  assert.equal(state.authorization.sessionId, 'session-a'); assert.equal(state.automatic, false);
  assert.deepEqual(state.results(), [{ type: 'result', id: 'r1', ok: true, value: 'opened:https://example.test/' }]);
});
test('scroll validates exact direction and forwards it to authorization and execution', async t => {
  const state = setup(); t.after(() => state.relay.close()); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'scroll', direction: 'down' });
  await settle(state); assert.equal(state.authorization.direction, 'down');
  assert.equal(state.results()[0].value, 'submitted:down');
  for (const extra of [{ direction: 'left' }, { direction: 400 }, { direction: 'up', code: 'x' }, {}]) {
    const bad = setup(); bad.send(ready); await tick();
    bad.send({ type: 'request', id: 'x', sessionId: 'session-a', operation: 'scroll', ...extra });
    assert.equal(bad.closed, 1); assert.equal(bad.authorization, undefined);
  }
});
test('denial sends no browser operation and returns a definitive denial', async t => {
  const state = setup(async () => false); t.after(() => state.relay.close()); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'observe' }); await settle(state);
  assert.deepEqual(state.results(), [{ type: 'result', id: 'r1', ok: false, error: 'Denied' }]);
});
test('automatic permission answers skip the dialog but keep binding and double-check', async t => {
  const state = setup(async () => true, true); t.after(() => state.relay.close()); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'observe' }); await settle(state);
  assert.equal(state.automatic, true);
  assert.equal(state.checks().length, 2, 'rechecked immediately before execution');
  assert.ok(state.checks().every(frame => frame.id === 'r1'));
  assert.equal(state.results()[0].ok, true);
});
test('a permission revoked between the two checks falls back to the dialog', async t => {
  const state = setup(async () => true, false); t.after(() => state.relay.close()); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'observe' }); await settle(state);
  assert.equal(state.checks().length, 1, 'no second check once manual');
  assert.equal(state.automatic, false);
  assert.equal(state.results()[0].ok, true);
});
test('a malformed or late approval reply closes the relay', async () => {
  const state = setup(); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'observe' });
  await tick();
  state.send({ type: 'policy', id: 'other', automatic: true });
  assert.equal(state.closed, 1);
  const late = setup(); late.send(ready); await tick();
  late.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'observe' });
  await settle(late);
  late.send({ type: 'policy', id: 'r1', automatic: true });
  assert.equal(late.closed, 1, 'a reply after the request finished is a protocol error');
});
test('closing while an approval check is pending never executes the request', async () => {
  const state = setup(async () => true, true, true); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'observe' });
  await tick();
  assert.equal(state.heldReplies.length, 1, 'waiting on the trusted permission answer');
  assert.equal(state.checks().length, 1);
  state.relay.close();
  assert.equal(state.closed, 1);
  state.heldReplies[0]();
  await settle(state);
  assert.equal(state.authorization, undefined, 'must not dispatch after closure');
  assert.equal(state.results().length, 0);
});
test('invalid URL or duplicate frame closes relay without dispatch', async () => {
  const state = setup(); state.send(ready); await tick();
  state.send({ type: 'request', id: 'r1', sessionId: 'session-a', operation: 'open', url: 'https://user:pass@example.test/' });
  assert.equal(state.closed, 1); assert.equal(state.authorization, undefined);
  const other = setup(); other.send(ready); await tick();
  other.send('{"type":"request","id":"x","id":"y","sessionId":"session-a","operation":"observe"}\n');
  assert.equal(other.closed, 1); assert.equal(other.authorization, undefined);
});
