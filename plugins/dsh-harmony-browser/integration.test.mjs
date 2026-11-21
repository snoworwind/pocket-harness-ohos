// Host-only simulation: this does not start ArkWeb or enable the DSH plugin.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { createMailbox } from './mailbox.js';
import { createBrowserCore, registerBrowserTools } from './index.js';

test('tool invocation reaches an explicitly approved simulated peer', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-flow-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const mailbox = createMailbox(root, { pollMs: 2 });
  const session = { id: 'session-test' };
  const ctx = { agents: { get: id => id === session.id ? session : undefined }, tools: { register: tool => definitions.push(tool) } };
  const definitions = [];
  const core = createBrowserCore({
    authorize: async (request, options) => options.agent === session && request.operation === 'observe',
    execute: (request, options) => mailbox.request(request, { timeoutMs: 2000, signal: options.signal }),
  });
  t.after(() => core.close());
  registerBrowserTools(ctx, tool => tool, core);
  const pending = definitions.find(tool => tool.name === 'browser_observe').execute({}, { agent: session });
  // authorize() is async; yield until the request has reached the mailbox.
  const slot = path.join(root, 'active');
  const requestFile = path.join(slot, 'request.json');
  for (let i = 0; i < 100 && !fs.existsSync(requestFile); i++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok(fs.existsSync(requestFile));
  const message = JSON.parse(fs.readFileSync(requestFile, 'utf8'));
  assert.deepEqual(message.payload, { operation: 'observe' });
  const temporary = path.join(slot, 'peer.tmp');
  fs.writeFileSync(temporary, JSON.stringify({ version: 1, id: message.id, result: 'simulated page' }), { flag: 'wx' });
  fs.linkSync(temporary, path.join(slot, 'response.json'));
  fs.unlinkSync(temporary);
  assert.equal(await pending, 'simulated page');
  assert.equal(fs.existsSync(slot), false);
});

test('denial never sends a mailbox request', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-deny-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const mailbox = createMailbox(root);
  const core = createBrowserCore({ authorize: async () => false, execute: (request, options) => mailbox.request(request, options) });
  t.after(() => core.close());
  await assert.rejects(core.request('observe'), /denied/);
  assert.deepEqual(fs.readdirSync(root), []);
});
