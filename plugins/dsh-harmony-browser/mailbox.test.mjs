import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { createMailbox, MAX_MESSAGE_BYTES } from './mailbox.js';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mailbox-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return { root, slot: path.join(root, 'active'), box: createMailbox(root, { pollMs: 2 }) };
}
function request(slot) { return JSON.parse(fs.readFileSync(path.join(slot, 'request.json'), 'utf8')); }
function respond(slot, value) {
  const temp = path.join(slot, 'peer.tmp');
  fs.writeFileSync(temp, JSON.stringify(value), { flag: 'wx' });
  fs.linkSync(temp, path.join(slot, 'response.json'));
  fs.unlinkSync(temp);
}

test('atomic request and correlated response; duplicate response cannot replace', async t => {
  const { box, slot } = fixture(t);
  const pending = box.request({ action: 'observe' }, { timeoutMs: 500 });
  const req = request(slot);
  assert.match(req.id, /^[0-9a-f]{32}$/);
  assert.deepEqual(req.payload, { action: 'observe' });
  assert.deepEqual(fs.readdirSync(slot), ['request.json']);
  respond(slot, { version: 1, id: req.id, result: 'ok' });
  assert.throws(() => respond(slot, { version: 1, id: req.id, result: 'again' }), { code: 'EEXIST' });
  assert.equal(await pending, 'ok');
  assert.equal(fs.existsSync(slot), false);
});

test('single slot rejects concurrent queue without altering request', async t => {
  const { box, slot } = fixture(t);
  const p = box.request('one', { timeoutMs: 500 });
  const id = request(slot).id;
  await assert.rejects(box.request('two'), /full or blocked/);
  assert.equal(request(slot).id, id);
  respond(slot, { version: 1, id, result: 'done' });
  await p;
});

test('abort persists revocation and permanently blocks slot', async t => {
  const { box, slot } = fixture(t);
  const controller = new AbortController();
  const p = box.request({}, { signal: controller.signal });
  const id = request(slot).id;
  controller.abort();
  await assert.rejects(p, /cancelled/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(slot, 'revoked.json'))), { version: 1, id });
  await assert.rejects(box.request({}), /blocked/);
});

test('timeout revokes durably and expired slot is not reused', async t => {
  const { box, slot } = fixture(t);
  const p = box.request({}, { timeoutMs: 10 });
  const id = request(slot).id;
  await assert.rejects(p, /timed out/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(slot, 'revoked.json'))).id, id);
  await assert.rejects(box.request({}), /blocked/);
});

test('mismatched or malformed responses fail closed', async t => {
  const { box, slot } = fixture(t);
  const p = box.request({}, { timeoutMs: 500 });
  const id = request(slot).id;
  respond(slot, { version: 1, id: 'other', result: 'bad' });
  await assert.rejects(p, /Invalid response/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(slot, 'revoked.json'))).id, id);
});

test('invalid input rejected before slot creation', async t => {
  const { box, root } = fixture(t);
  await assert.rejects(box.request('x'.repeat(MAX_MESSAGE_BYTES)), /oversized/);
  await assert.rejects(box.request({}, { timeoutMs: 0 }), /timeout/);
  assert.deepEqual(fs.readdirSync(root), []);
});
