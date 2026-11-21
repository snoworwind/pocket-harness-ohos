'use strict';
// Host simulation only: this does not supply an OHOS backend or exercise ArkWeb.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/platform/BrowserMailbox.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const sandbox = { exports: {}, Date, JSON, Object, Array, Number, String, Error, Promise,
  require: name => { assert.equal(name, '@kit.ArkTS'); return { url: { URL } }; } };
vm.runInNewContext(js, sandbox);
const { BrowserMailbox } = sandbox.exports;
const generation = 'a'.repeat(48);
function setup(payload = { operation: 'observe' }) {
  const log = [];
  let revoked = false;
  const envelope = { version: 2, generation, deadline: Date.now() + 30000, payload };
  const backend = {
    async listActive() { log.push('list'); return generation; },
    async readRequest() { log.push('read'); return JSON.stringify(envelope); },
    async tryClaim() { log.push('claim'); return true; },
    async revoked() { log.push('revoked'); return revoked; },
    async publishResponse(root, gen, json, limit) { log.push('publish'); assert.equal(gen, generation); assert.equal(limit, 65536); this.response = JSON.parse(json); },
    async makeDone() { log.push('done'); },
  };
  return { mailbox: new BrowserMailbox('/private/test', backend), backend, log, envelope, revoke: () => { revoked = true; } };
}

test('claim requires explicit completion and completes only once', async () => {
  const state = setup(); const claim = await state.mailbox.readAndClaim();
  assert.ok(claim); assert.deepEqual(JSON.parse(JSON.stringify(claim.describe())), { operation: 'observe' });
  assert.deepEqual(state.log, ['list', 'read', 'claim', 'revoked']);
  let executed = 0;
  assert.equal(await claim.completeAuthorized(async () => { executed++; return 'observed'; }), true);
  assert.equal(executed, 1); assert.equal(state.backend.response.value, 'observed');
  assert.deepEqual(state.log.slice(-3), ['revoked', 'publish', 'done']);
  await assert.rejects(claim.completeAuthorized(async () => 'again'), /consumed/);
  assert.equal(state.log.at(-1), 'done');
});

test('revocation between claim and authorization stops execution', async () => {
  const state = setup(); const claim = await state.mailbox.readAndClaim(); state.revoke();
  let executed = 0;
  assert.equal(await claim.completeAuthorized(async () => { executed++; return 'bad'; }), false);
  assert.equal(executed, 0); assert.ok(!state.log.includes('publish')); assert.ok(!state.log.includes('done'));
});

test('expired and invalid payloads never get claimed', async () => {
  const expired = setup(); expired.envelope.deadline = Date.now() - 1;
  assert.equal(await expired.mailbox.readAndClaim(), null); assert.ok(!expired.log.includes('claim'));
  const invalid = setup({ operation: 'execute', script: 'alert(1)' });
  await assert.rejects(invalid.mailbox.readAndClaim(), /invalid mailbox payload/); assert.ok(!invalid.log.includes('claim'));
});

test('open accepts only credential-free HTTP(S) URLs before claim', async () => {
  for (const url of ['file:///data/private', 'javascript:alert(1)', 'https://name:secret@example.test/', 'https://example.test/\n']) {
    const state = setup({ operation: 'open', url });
    await assert.rejects(state.mailbox.readAndClaim(), /invalid browser URL/);
    assert.ok(!state.log.includes('claim'));
  }
  const allowed = setup({ operation: 'open', url: 'https://example.test/' });
  assert.ok(await allowed.mailbox.readAndClaim());
});

test('execution errors are reported once without exposing further operations', async () => {
  const state = setup(); const claim = await state.mailbox.readAndClaim();
  assert.equal(await claim.completeAuthorized(async () => { throw Error('failed'); }), true);
  assert.equal(state.backend.response.ok, false); assert.match(state.backend.response.value, /failed/);
  assert.equal(state.log.at(-1), 'done');
});
