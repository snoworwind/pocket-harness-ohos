// Real local relay + private file + client; the native browser is simulated.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createCredentialProvider } from './credential-provider.js';
import { connectRelay } from './client-relay.js';

test('published private credentials connect an approved simulated operation', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-published-'));
  const home = path.join(root, 'harness-home'); fs.mkdirSync(home, { mode: 0o700 });
  const prior = process.env.DSH_HOME; process.env.DSH_HOME = home;
  const child = spawn(process.execPath, ['--jitless', new URL('./relay.cjs', import.meta.url).pathname, '--publish-ready'], {
    env: { ...process.env, DSH_HOME: home }, stdio: ['pipe', 'pipe', 'pipe']
  });
  child.stderr.resume(); child.stdin.on('error', () => {});
  const lines = createInterface({ input: child.stdout }); const queue = [], waiters = [];
  lines.on('line', line => { const frame = JSON.parse(line); const waiter = waiters.shift(); waiter ? waiter(frame) : queue.push(frame); });
  const next = () => queue.length ? Promise.resolve(queue.shift()) : new Promise(resolve => waiters.push(resolve));
  t.after(() => { child.kill(); lines.close(); if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior; fs.rmSync(root, { recursive: true, force: true }); });
  const ready = await next(); assert.equal(ready.type, 'ready');
  const agent = { id: 'session-test' }, signal = new AbortController().signal;
  const provider = createCredentialProvider({ agents: { get: id => id === agent.id ? agent : undefined } });
  const credentials = await provider.getCredentials({ agent, signal });
  assert.equal(credentials.port, ready.port); assert.equal(credentials.credential, ready.credential);
  const client = await connectRelay({ ...credentials, sessionId: agent.id }); t.after(() => client.close());
  const pending = client.request('observe', { signal });
  const request = await next(); assert.equal(request.sessionId, agent.id); assert.equal(request.operation, 'observe');
  child.stdin.write(JSON.stringify({ type: 'result', id: request.id, ok: true, value: 'simulated title' }) + '\n');
  assert.equal((await pending).value, 'simulated title');
  client.close(); child.stdin.end();
});
