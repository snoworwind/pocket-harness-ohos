// Opt-in, same-UID file transport. This module does not register a plugin.
// See the protocol constants and createMailbox contract below; the peer is trusted.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';

export const MAX_MESSAGE_BYTES = 65536;
export const MAX_TIMEOUT_MS = 300000;
const SLOT = 'active';

function syncDir(dir) {
  const fd = fs.openSync(dir, 'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function commit(dir, name, data) {
  const tmp = path.join(dir, `.tmp-${randomBytes(16).toString('hex')}`);
  let fd;
  try {
    fd = fs.openSync(tmp, 'wx', 0o600);
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
    fs.closeSync(fd); fd = undefined;
    // The name is private to this producer and never replaced.
    fs.linkSync(tmp, path.join(dir, name));
    syncDir(dir);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    try { fs.unlinkSync(tmp); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
}
function encode(value) {
  const text = JSON.stringify(value);
  if (typeof text !== 'string' || Buffer.byteLength(text) > MAX_MESSAGE_BYTES) throw new Error('Invalid or oversized message');
  return text;
}
function readResponse(file, id) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > MAX_MESSAGE_BYTES || st.size < 2) throw new Error('Invalid response size');
    const bytes = Buffer.alloc(st.size + 1);
    const n = fs.readSync(fd, bytes, 0, bytes.length, 0);
    if (n !== st.size) throw new Error('Response changed while reading');
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, n));
    const obj = JSON.parse(text);
    if (!obj || Array.isArray(obj) || typeof obj !== 'object' || Object.keys(obj).sort().join(',') !== 'id,result,version' || obj.version !== 1 || obj.id !== id || typeof obj.result !== 'string') throw new Error('Invalid response');
    return obj.result;
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}

/**
 * root must be a pre-existing, private, trusted same-UID directory, on a local
 * filesystem supporting mkdir, hard links and fsync. Exactly one outstanding
 * request is allowed across all producers. A failed/cancelled slot is retained
 * permanently; recovery requires stopping both peers and manual inspection.
 * request(payload, {timeoutMs, signal}) accepts JSON payload, returns a string.
 */
export function createMailbox(root, { pollMs = 25 } = {}) {
  if (typeof root !== 'string' || !path.isAbsolute(root) || !Number.isSafeInteger(pollMs) || pollMs < 1 || pollMs > 1000) throw new TypeError('Invalid mailbox configuration');
  const stat = fs.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Mailbox root must be a directory');
  const slot = path.join(root, SLOT);
  return {
    request(payload, { timeoutMs = 30000, signal } = {}) {
      return new Promise((resolve, reject) => {
        let timer, abort, published = false, finished = false;
        let id;
        const finish = (err, result) => {
          if (finished) return;
          finished = true;
          clearTimeout(timer);
          if (abort) signal?.removeEventListener('abort', abort);
          if (err && published) {
            try { commit(slot, 'revoked.json', encode({ version: 1, id })); }
            catch (revokeError) { err = new AggregateError([err, revokeError], 'Request failed and durable revocation failed; mailbox remains blocked'); }
          }
          if (!err) {
            try {
              // Only a completed response permits reuse; a peer must have stopped work.
              fs.rmSync(slot, { recursive: true });
              syncDir(root);
            } catch (cleanupError) { err = cleanupError; }
          }
          err ? reject(err) : resolve(result);
        };
        try {
          if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > MAX_TIMEOUT_MS) throw new TypeError('Invalid timeout');
          if (signal?.aborted) throw new Error('Request cancelled');
          id = randomBytes(16).toString('hex');
          const deadline = Date.now() + timeoutMs;
          const body = encode({ version: 1, id, deadline, payload });
          if (!Object.hasOwn(JSON.parse(body), 'payload')) throw new TypeError('Invalid payload');
          try { fs.mkdirSync(slot, { mode: 0o700 }); }
          catch (e) { if (e.code === 'EEXIST') throw new Error('Mailbox full or blocked'); throw e; }
          syncDir(root);
          // Set before commit: a partial commit or sync error must revoke too.
          published = true;
          commit(slot, 'request.json', body);
          abort = () => finish(new Error('Request cancelled'));
          signal?.addEventListener('abort', abort, { once: true });
          const poll = () => {
            if (finished) return;
            if (signal?.aborted) return finish(new Error('Request cancelled'));
            if (Date.now() >= deadline) return finish(new Error('Request timed out'));
            try {
              const result = readResponse(path.join(slot, 'response.json'), id);
              if (Date.now() >= deadline) return finish(new Error('Request timed out'));
              return finish(null, result);
            } catch (e) { if (e.code !== 'ENOENT') return finish(e); }
            timer = setTimeout(poll, Math.min(pollMs, Math.max(1, deadline - Date.now())));
          };
          poll();
        } catch (e) { finish(e); }
      });
    }
  };
}
