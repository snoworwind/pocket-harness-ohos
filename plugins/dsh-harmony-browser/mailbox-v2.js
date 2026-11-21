// Experimental Node-only mailbox; not registered or enabled by this module.
//
// Layout: root/active/<random-generation>/{request,claim,response,done,revoke}.
// All peers must cooperate, use the same trusted private root, and never reuse a
// generation. A single live producer owns each handle: concurrent wait/cancel or
// recovery by another producer is not supported. Failure leaves active in place;
// there is deliberately no automatic recovery, stale-lock breaking or replay.
//
// Required but NOT validated on ArkTS/OHOS: mkdir is atomic and exclusive across
// processes; same-filesystem rename is atomic and does not replace a nonempty
// directory; file fsync and directory fsync persist writes/renames/mkdir across
// power loss, with coherent cross-process visibility. Node host tests cannot
// establish these properties on the target. Root and all ancestors must already
// exist, be private, and not be modified by outsiders or symlinks. A crash in any
// transitional state can strand the slot indefinitely, including after done.
// Cancel is a persistent best-effort intent, not a guarantee that an action
// already started (or racing the revoke check) will not execute. Deadline is
// checked immediately before invocation, but clock changes or expiry between that
// check and invocation can still race; it cannot stop an already started action.

import * as fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

const id = () => randomBytes(24).toString('hex');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const isMissing = e => e?.code === 'ENOENT';
async function exists(p) {
  try { await fs.stat(p); return true; } catch (e) { if (isMissing(e)) return false; throw e; }
}
async function syncDir(p) {
  const h = await fs.open(p, 'r');
  try { await h.sync(); } finally { await h.close(); }
}
async function marker(p) {
  await fs.mkdir(p);
  await syncDir(path.dirname(p));
}
const MAX_BYTES = 64 * 1024;
async function publish(dir, name, value) {
  const bytes = Buffer.from(JSON.stringify(value), 'utf8');
  if (bytes.length > MAX_BYTES) throw new Error('mailbox file too large');
  const tmp = path.join(dir, `.${name}-${id()}`);
  const h = await fs.open(tmp, 'wx', 0o600);
  try { await h.writeFile(bytes); await h.sync(); } finally { await h.close(); }
  await fs.rename(tmp, path.join(dir, name));
  await syncDir(dir);
}
async function readJson(p) {
  const h = await fs.open(p, 'r');
  try {
    const buffer = Buffer.alloc(MAX_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await h.read(buffer, length, buffer.length - length, length);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > MAX_BYTES) throw new Error('mailbox file too large');
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, length)));
  } finally { await h.close(); }
}
function validId(s) { return typeof s === 'string' && /^[0-9a-f]{48}$/.test(s); }
function exactKeys(obj, keys) {
  return obj !== null && typeof obj === 'object' && !Array.isArray(obj) &&
    Object.keys(obj).length === keys.length && keys.every(k => Object.hasOwn(obj, k));
}
function validateEnvelope(obj, generation, keys) {
  if (!exactKeys(obj, ['version', 'generation', ...keys]) || obj.version !== 2 ||
      obj.generation !== generation || !validId(generation)) {
    throw new Error('invalid mailbox envelope');
  }
}
// The experimental protocol accepts only these two operations, without arbitrary
// command fields. open carries a URL; observe has no arguments.
function validatePayload(payload) {
  if (exactKeys(payload, ['operation', 'url']) && payload.operation === 'open' &&
      typeof payload.url === 'string' && payload.url.length > 0) return;
  if (exactKeys(payload, ['operation']) && payload.operation === 'observe') return;
  throw new Error('invalid mailbox payload');
}
function validateDeadline(deadline) {
  if (!Number.isSafeInteger(deadline) || deadline <= 0) throw new Error('invalid mailbox deadline');
}

// root must exist. Ownership starts as soon as mkdir(active) succeeds, even if
// later publication fails. Never delete on failure; an operator must inspect it.
export async function createRequest(root, payload, { deadline = Date.now() + 5000 } = {}) {
  validatePayload(payload);
  validateDeadline(deadline);
  if (Date.now() >= deadline) throw new Error('mailbox deadline expired');
  const active = path.join(root, 'active');
  const generation = id();
  await fs.mkdir(active);
  const dir = path.join(active, generation);
  try {
    await syncDir(root);
    await marker(dir);
    await publish(dir, 'request', { version: 2, generation, deadline, payload });
    const check = await readJson(path.join(dir, 'request'));
    validateEnvelope(check, generation, ['deadline', 'payload']);
    // Verify the actual published bytes, not merely the envelope.
    if (JSON.stringify(check) !== JSON.stringify({ version: 2, generation, deadline, payload })) {
      throw new Error('request verification failed');
    }
    return { root, generation };
  } catch (error) {
    try {
      // The generation directory may not have been created yet.
      try { await marker(path.join(active, 'revoke')); }
      catch (e) { if (e.code !== 'EEXIST') throw e; await syncDir(active); }
    } catch (revokeError) {
      throw new AggregateError([error, revokeError], 'publication failed; revoke could not be persisted');
    }
    throw error;
  }
}

// On timeout/error write a durable revoke marker; if that fails, surface the
// failure and still leave the slot untouched. No cleanup on any failure.
export async function revoke(handle) {
  const dir = path.join(handle.root, 'active', handle.generation);
  try { await marker(path.join(dir, 'revoke')); }
  catch (e) { if (e.code !== 'EEXIST') throw e; await syncDir(dir); }
}

export async function waitResponse(handle, { timeoutMs = 5000, pollMs = 10 } = {}) {
  if (!validId(handle.generation)) throw new Error('invalid generation');
  const { root, generation } = handle;
  const dir = path.join(root, 'active', generation);
  const deadline = Date.now() + timeoutMs;
  let detached = false;
  try {
    while (true) {
      if (Date.now() >= deadline) throw new Error('mailbox timeout');
      if (await exists(path.join(dir, 'revoke'))) throw new Error('mailbox revoked');
      if (await exists(path.join(dir, 'done'))) break;
      await pause(pollMs);
    }
    const response = await readJson(path.join(dir, 'response'));
    if (Date.now() >= deadline) throw new Error('mailbox timeout');
    if (await exists(path.join(dir, 'revoke'))) throw new Error('mailbox revoked');
    validateEnvelope(response, generation, ['ok', 'value']);
    if (typeof response.ok !== 'boolean' || !Object.hasOwn(response, 'value')) throw new Error('invalid response');
    // Rename the entire active slot before recursive deletion. A stale receiver
    // can never act on a replacement generation after this atomic detach.
    const trash = path.join(root, `.completed-${generation}`);
    await fs.rename(path.join(root, 'active'), trash);
    detached = true;
    await syncDir(root);
    await fs.rm(trash, { recursive: true });
    await syncDir(root);
    return response;
  } catch (error) {
    if (detached) throw error; // active may already be a different generation
    try { await revoke(handle); } catch (revokeError) {
      throw new AggregateError([error, revokeError], 'mailbox failed; revoke could not be persisted');
    }
    throw error;
  }
}

// A receiver may poll this repeatedly. It only acts after winning claim and
// checking revocation. Once done is created it performs NO slot access, even
// on error: producers may immediately detach/delete and reuse active.
export async function receiveOnce(root, execute) {
  const active = path.join(root, 'active');
  let entries;
  try { entries = await fs.readdir(active); } catch (e) { if (isMissing(e)) return false; throw e; }
  const generations = entries.filter(validId);
  if (generations.length !== 1) return false;
  const generation = generations[0];
  const dir = path.join(active, generation);
  let request;
  try { request = await readJson(path.join(dir, 'request')); }
  catch (e) { if (isMissing(e)) return false; throw e; }
  validateEnvelope(request, generation, ['deadline', 'payload']);
  validateDeadline(request.deadline);
  validatePayload(request.payload);
  if (Date.now() >= request.deadline) return false;
  try { await fs.mkdir(path.join(dir, 'claim')); }
  catch (e) { if (e.code === 'EEXIST' || isMissing(e)) return false; throw e; }
  await syncDir(dir);
  if (await exists(path.join(active, 'revoke')) || await exists(path.join(dir, 'revoke'))) return false;
  if (Date.now() >= request.deadline) return false;
  let response;
  try { response = { version: 2, generation, ok: true, value: await execute(request.payload) }; }
  catch (e) { response = { version: 2, generation, ok: false, value: String(e?.message ?? e) }; }
  await publish(dir, 'response', response);
  // Do not fsync the containing directory after mkdir(done): that would access
  // the slot after done. Durability therefore additionally requires mkdir(done)
  // itself to be durable, a target-platform requirement not proven here.
  await fs.mkdir(path.join(dir, 'done'));
  return true;
}
