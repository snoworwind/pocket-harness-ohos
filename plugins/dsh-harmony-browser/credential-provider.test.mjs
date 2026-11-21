import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, chmod, symlink, link, lstat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createCredentialProvider } from './credential-provider.js';
import { registerRelayTools } from './index.js';

test('private ready validation, fresh reads, and sanitized failures', async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'browser-provider-'));
  const old = process.env.DSH_HOME;
  const dir = path.join(root, 'browser-managed'), file = path.join(dir, 'ready.json');
  const agent = { id: 'agent' }, signal = new AbortController().signal;
  const ctx = { agents: { get: id => id === agent.id ? agent : undefined } };
  const provider = createCredentialProvider(ctx);
  const secret = 'a'.repeat(64);
  const ready = () => ({ version: 1, host: '127.0.0.1', port: 1234, credential: secret, expiresAt: Date.now() + 60000 });
  const put = async value => { await writeFile(file, value, { mode: 0o600 }); await chmod(file, 0o600); };
  const reject = async () => assert.rejects(provider.getCredentials({ agent, signal }), e => !e.message.includes(secret));
  try {
    process.env.DSH_HOME = path.join(root, 'harness-home');
    await mkdir(dir, { mode: 0o700 });
    await put(JSON.stringify(ready()));
    assert.equal((await provider.getCredentials({ agent, signal })).credential, secret);
    await put(JSON.stringify({ ...ready(), port: 4321 }));
    assert.equal((await provider.getCredentials({ agent, signal })).port, 4321);
    for (const value of [ { ...ready(), expiresAt: Date.now() - 1 }, { ...ready(), expiresAt: Date.now() + 600000 }, { ...ready(), extra: secret }, { ...ready(), type: 'ready' }, { ...ready(), host: 'localhost' }, { ...ready(), credential: 'A'.repeat(64) } ]) { await put(JSON.stringify(value)); await reject(); }
    await put(Buffer.from([0xff])); await reject();
    await put('x'.repeat(1025)); await reject();
    await put(JSON.stringify(ready())); await chmod(file, 0o644); await reject();
    await chmod(file, 0o600); await chmod(dir, 0o755); await reject(); await chmod(dir, 0o700);
    await link(file, path.join(dir, 'hardlink'));
    if ((await lstat(file)).nlink > 1) await reject();
    else t.diagnostic('filesystem reports nlink=1 after link; hard-link rejection cannot be verified here');
    await rm(path.join(dir, 'hardlink'));
    await rm(file); await symlink('/dev/null', file); await reject();
    await rm(file); await put(JSON.stringify(ready()));
    ctx.agents.get = () => undefined; await reject();
  } finally {
    if (old === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = old;
    await rm(root, { recursive: true, force: true });
  }
});

test('provider exceptions and credential content do not escape tools', async () => {
  const agent = { id: 'agent' }, defs = [], secret = 'sensitive-output';
  const ctx = { agents: { get: () => agent }, tools: { register: d => defs.push(d) } };
  registerRelayTools(ctx, d => d, async () => { throw Error(secret); }, { getCredentials: async () => { throw Error(secret); } });
  await assert.rejects(defs[0].execute({ url: 'https://example.org' }, { agent, signal: new AbortController().signal }), e => !e.message.includes(secret));
});
