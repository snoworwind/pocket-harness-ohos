import { constants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import path from 'node:path';
import { TextDecoder } from 'node:util';

// Native publishes relay connection fields plus expiresAt (Unix milliseconds) via
// an atomic rename into this private directory. Same-UID code is trusted.
const LIMIT = 1024;
const MAX_LIFETIME_MS = 5 * 60 * 1000;
const failure = () => new Error('Private browser credentials unavailable');

export function createCredentialProvider(ctx) {
  return Object.freeze({ async getCredentials({ agent, signal } = {}) {
    const live = () => {
      if (!agent || typeof agent.id !== 'string' || ctx?.agents?.get(agent.id) !== agent || !signal || signal.aborted || typeof signal.addEventListener !== 'function') throw failure();
    };
    let handle;
    try {
      live();
      const home = process.env.DSH_HOME;
      if (typeof home !== 'string' || !path.isAbsolute(home) || home === '/') throw failure();
      if (typeof process.getuid !== 'function' || !constants.O_NOFOLLOW || !constants.O_NONBLOCK) throw failure();
      const uid = process.getuid();
      const dir = path.join(path.dirname(path.resolve(home)), 'browser-managed');
      const dirStat = await lstat(dir);
      if (!dirStat.isDirectory() || dirStat.uid !== uid || (dirStat.mode & 0o077) !== 0) throw failure();
      const file = path.join(dir, 'ready.json');
      const before = await lstat(file);
      const validFile = s => s.isFile() && s.uid === uid && (s.mode & 0o177) === 0 && s.nlink === 1 && s.size > 0 && s.size <= LIMIT;
      if (!validFile(before)) throw failure();
      handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const opened = await handle.stat();
      if (!validFile(opened) || opened.dev !== before.dev || opened.ino !== before.ino) throw failure();
      const bytes = Buffer.alloc(LIMIT + 1);
      let used = 0;
      while (used < bytes.length) {
        const { bytesRead } = await handle.read(bytes, used, bytes.length - used, null);
        if (!bytesRead) break;
        used += bytesRead;
      }
      const after = await handle.stat();
      if (used > LIMIT || used !== opened.size || !validFile(after) || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) throw failure();
      const data = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, used)));
      const keys = ['version', 'host', 'port', 'credential', 'expiresAt'];
      const now = Date.now();
      if (!data || typeof data !== 'object' || Array.isArray(data) || Object.keys(data).length !== keys.length || !keys.every(k => Object.hasOwn(data, k)) || data.version !== 1 || data.host !== '127.0.0.1' || !Number.isInteger(data.port) || data.port < 1 || data.port > 65535 || typeof data.credential !== 'string' || !/^[a-f0-9]{64}$/.test(data.credential) || !Number.isSafeInteger(data.expiresAt) || data.expiresAt <= now || data.expiresAt > now + MAX_LIFETIME_MS) throw failure();
      live();
      return { host: data.host, port: data.port, credential: data.credential };
    } catch { throw failure(); }
    finally { if (handle) await handle.close().catch(() => {}); }
  } });
}
