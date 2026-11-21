import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequest, receiveOnce, revoke, waitResponse } from './mailbox-v2.js';

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'mailbox-v2-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}
const slot = (root, h) => path.join(root, 'active', h.generation);

test('exclusive slot, competing receivers and verified response', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'open', url: 'https://example.test' });
  await assert.rejects(createRequest(root, { operation: 'observe' }), { code: 'EEXIST' });
  let calls = 0;
  const outcomes = await Promise.all(Array.from({ length: 30 }, () => receiveOnce(root, async p => {
    calls++; await new Promise(r => setTimeout(r, 5)); return p.url;
  })));
  assert.equal(calls, 1);
  assert.equal(outcomes.filter(Boolean).length, 1);
  const result = await waitResponse(h);
  assert.deepEqual(result, { version: 2, generation: h.generation, ok: true, value: 'https://example.test' });
  await assert.rejects(fs.stat(path.join(root, 'active')), { code: 'ENOENT' });
});

test('timeout persists revoke and does not remove slot', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  await assert.rejects(waitResponse(h, { timeoutMs: 0 }), /timeout/);
  assert.ok((await fs.stat(path.join(slot(root, h), 'revoke'))).isDirectory());
  let calls = 0;
  assert.equal(await receiveOnce(root, () => calls++), false);
  assert.equal(calls, 0);
  await assert.rejects(createRequest(root, { operation: 'observe' }), { code: 'EEXIST' });
});

test('claimed crash is not replayed after receiver restart', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  await fs.mkdir(path.join(slot(root, h), 'claim')); // crash after claim
  let calls = 0;
  assert.equal(await receiveOnce(root, () => calls++), false);
  assert.equal(calls, 0);
  await assert.rejects(waitResponse(h, { timeoutMs: 0 }), /timeout/);
  assert.ok(await fs.stat(path.join(slot(root, h), 'revoke')));
});

test('completed crash can be read on producer restart with saved handle', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  await receiveOnce(root, () => 'finished');
  const recovered = JSON.parse(JSON.stringify(h));
  assert.equal((await waitResponse(recovered)).value, 'finished');
});

test('stale generation paths cannot claim a replacement after done cleanup', async t => {
  const root = await fixture(t);
  const old = await createRequest(root, { operation: 'observe' });
  await receiveOnce(root, () => 2);
  await waitResponse(old);
  const current = await createRequest(root, { operation: 'observe' });
  assert.notEqual(old.generation, current.generation);
  await assert.rejects(fs.mkdir(path.join(slot(root, old), 'claim')), { code: 'ENOENT' });
  assert.equal(await receiveOnce(root, () => 2), true);
  assert.equal((await waitResponse(current)).value, 2);
});

test('invalid response is retained and revoked, never cleaned', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  await receiveOnce(root, () => 2);
  await fs.writeFile(path.join(slot(root, h), 'response'), '{"version":2}');
  await assert.rejects(waitResponse(h), /invalid mailbox envelope/);
  assert.ok(await fs.stat(path.join(slot(root, h), 'revoke')));
  assert.ok(await fs.stat(path.join(slot(root, h), 'done')));
});

test('revocation is best effort after execution begins', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  let started;
  const ready = new Promise(r => { started = r; });
  let release;
  const gate = new Promise(r => { release = r; });
  const receiving = receiveOnce(root, async () => { started(); await gate; return 'executed'; });
  await ready;
  await revoke(h);
  release();
  assert.equal(await receiving, true);
  await assert.rejects(waitResponse(h), /revoked/);
  assert.ok(await fs.stat(path.join(slot(root, h), 'done')));
});


test('only exact open and observe payloads are accepted', async t => {
  const root = await fixture(t);
  for (const payload of [null, {}, { operation: 'execute' }, { operation: 'observe', command: 'x' },
    { operation: 'open' }, { operation: 'open', url: 1 }]) {
    await assert.rejects(createRequest(root, payload), /invalid mailbox payload/);
  }
  await assert.rejects(createRequest(root, { operation: 'observe' }, { deadline: Date.now() - 1 }), /expired/);
  await assert.rejects(createRequest(root, { operation: 'observe' }, { deadline: Infinity }), /deadline/);
});

test('expired request cannot be invoked', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  const requestPath = path.join(slot(root, h), 'request');
  const request = JSON.parse(await fs.readFile(requestPath, 'utf8'));
  request.deadline = Date.now() - 1;
  await fs.writeFile(requestPath, JSON.stringify(request));
  let calls = 0;
  assert.equal(await receiveOnce(root, () => calls++), false);
  assert.equal(calls, 0);
});

test('request rejects malformed envelopes, UTF-8 and oversized files', async t => {
  const root = await fixture(t);
  const h = await createRequest(root, { operation: 'observe' });
  const requestPath = path.join(slot(root, h), 'request');
  const original = JSON.parse(await fs.readFile(requestPath, 'utf8'));
  let calls = 0;
  for (const invalid of [
    Buffer.from([0xff]), Buffer.alloc(65537, 0x20),
    JSON.stringify({ ...original, extra: true }),
    JSON.stringify({ ...original, deadline: '123' }),
    JSON.stringify({ ...original, payload: { operation: 'delete' } }),
  ]) {
    await fs.writeFile(requestPath, invalid);
    await assert.rejects(receiveOnce(root, () => calls++));
  }
  assert.equal(calls, 0);
});

test('response rejects extra fields and invalid UTF-8 without cleanup', async t => {
  for (const bytes of [Buffer.from([0xc3, 0x28]), Buffer.alloc(65537, 0x20), 'extra']) {
    const root = await fixture(t);
    const h = await createRequest(root, { operation: 'observe' });
    await receiveOnce(root, () => 'ok');
    const responsePath = path.join(slot(root, h), 'response');
    const invalid = bytes === 'extra' ? JSON.stringify({ version: 2, generation: h.generation, ok: true, value: 1, extra: 1 }) : bytes;
    await fs.writeFile(responsePath, invalid);
    await assert.rejects(waitResponse(h));
    assert.ok(await fs.stat(path.join(slot(root, h), 'revoke')));
  }
});

test('publication rejects oversized serialized request and response', async t => {
  const root = await fixture(t);
  await assert.rejects(createRequest(root, { operation: 'open', url: '界'.repeat(30000) }), /too large/);
  const root2 = await fixture(t);
  const h = await createRequest(root2, { operation: 'observe' });
  await assert.rejects(receiveOnce(root2, () => 'x'.repeat(65536)), /too large/);
  await assert.rejects(waitResponse(h, { timeoutMs: 0 }), /timeout/);
});
