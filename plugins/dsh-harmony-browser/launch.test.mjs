import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, lstat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { requestBrowserLaunch } from './launch.js';

test('launch publishes the session and removes its request after credentials arrive', { skip: typeof process.getuid !== 'function' }, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'browser-launch-'));
  const previous = process.env.DSH_HOME;
  process.env.DSH_HOME = path.join(root, 'home');
  await mkdir(process.env.DSH_HOME);
  try {
    let calls = 0;
    const agent = { id: 'session-1' };
    const expected = { host: '127.0.0.1', port: 10, credential: 'x' };
    const provider = { async getCredentials() {
      const file = path.join(root, 'browser-managed', 'launch-request.json');
      const request = JSON.parse(await readFile(file, 'utf8'));
      assert.equal(request.sessionId, agent.id);
      assert.equal(request.version, 1);
      assert.match(request.id, /^[a-f0-9]{32}$/);
      if (++calls === 1) throw new Error('not ready');
      return expected;
    } };
    assert.deepEqual(await requestBrowserLaunch(provider, { agent, signal: new AbortController().signal }), expected);
    await assert.rejects(lstat(path.join(root, 'browser-managed', 'launch-request.json')), { code: 'ENOENT' });
  } finally {
    if (previous === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = previous;
    await rm(root, { recursive: true, force: true });
  }
});
