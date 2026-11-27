import { constants } from 'node:fs';
import { mkdir, lstat, open, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

// A launch request carries no URL or authority to act on a page. The native
// host opens only the matching visible session and retains its normal checks.
export async function requestBrowserLaunch(provider, { agent, signal, timeoutMs = 20000 }) {
  if (!agent || !/^[A-Za-z0-9_-]{1,128}$/.test(agent.id) || !signal || signal.aborted) throw new Error('Invalid browser launch');
  const home = process.env.DSH_HOME;
  if (!home || !path.isAbsolute(home) || home === '/') throw new Error('Browser home unavailable');
  const dir = path.join(path.dirname(path.resolve(home)), 'browser-managed');
  await mkdir(dir, { mode: 0o700 }).catch(error => { if (error.code !== 'EEXIST') throw error; });
  const st = await lstat(dir);
  if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('Invalid browser directory');
  const file = path.join(dir, 'launch-request.json');
  let handle, own;
  try {
    handle = await open(file, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
    own = await handle.stat();
    const deadline = Date.now() + timeoutMs;
    await handle.writeFile(JSON.stringify({ version: 1, id: randomBytes(16).toString('hex'), sessionId: agent.id, deadline }));
    await handle.close(); handle = undefined;
    while (Date.now() < deadline && !signal.aborted) {
      try { return await provider.getCredentials({ agent, signal }); } catch { /* wait for the visible host */ }
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    throw new Error('Browser launch timed out');
  } finally {
    await handle?.close().catch(() => {});
    if (own) {
      try { const current = await lstat(file); if (current.dev === own.dev && current.ino === own.ino) await unlink(file); } catch {}
    }
  }
}
