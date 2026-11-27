'use strict';
// Argument-validation matrix for the tool adapter.
//
// Every rejection here must happen *before* a relay connection is made: a
// malformed argument must never reach the native side, because that is where
// real user data lives. The fake connect() records calls, so "no call" is
// asserted directly rather than inferred.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

const plugin = path.join(__dirname, '..', 'plugins', 'dsh-harmony-browser');

async function setup() {
  const { registerRelayTools } = await import(path.join(plugin, 'index.js'));
  const agent = { id: 'session-validation' };
  const defs = [];
  const calls = [];
  const ctx = {
    agents: { get: id => (id === agent.id ? agent : undefined) },
    tools: { register: definition => defs.push(definition) },
    harmonyBrowserRelay: {
      async getCredentials() { return { host: '127.0.0.1', port: 1, credential: 'a'.repeat(64) }; }
    }
  };
  const connect = async options => {
    calls.push(['connect', options]);
    return {
      async request(operation, args) { calls.push(['request', operation, args]); return { ok: true, value: 'ok' }; },
      close() { calls.push(['close']); }
    };
  };
  registerRelayTools(ctx, definition => definition, connect);
  const tool = name => {
    const found = defs.find(d => d.name === name);
    if (!found) throw new Error('missing tool ' + name);
    return found;
  };
  const signal = new AbortController().signal;
  return { agent, defs, calls, tool, signal, exec: { agent, signal } };
}

function assertRejectedBeforeConnect(calls, exec, args, pattern) {
  const before = calls.length;
  return Promise.resolve()
    .then(() => exec(args))
    .then(() => { throw new Error('expected rejection, got success'); },
      error => {
        if (pattern) assert.match(String(error.message), pattern);
        assert.equal(calls.length, before, 'a rejected argument must not open a relay connection');
      });
}

test('open rejects every non-http(s), credentialed or oversized URL before connecting', async () => {
  const { tool, calls, exec } = await setup();
  const open = tool('browser_open');
  const bad = [
    {}, { url: '' }, { url: 42 }, { url: null },
    { url: 'file:///etc/passwd' }, { url: 'javascript:alert(1)' }, { url: 'data:text/html,x' },
    { url: 'ftp://example.test/' }, { url: 'https://user:pw@example.test/' },
    { url: 'https://example.test/a b' }, { url: 'https://example.test/\u0000' },
    { url: 'https://example.test/' + 'a'.repeat(5000) },
    { url: 'https://example.test/', extra: 1 }
  ];
  for (const args of bad) {
    await assertRejectedBeforeConnect(calls, a => open.execute(a, exec), args);
  }
});

test('observe and navigate take no free-form arguments', async () => {
  const { tool, calls, exec } = await setup();
  const observe = tool('browser_observe');
  await assertRejectedBeforeConnect(calls, a => observe.execute(a, exec), { anything: 1 });
  const navigate = tool('browser_navigate');
  for (const args of [{}, { action: 'reload' }, { action: 'back', extra: 1 }, { action: 1 }]) {
    await assertRejectedBeforeConnect(calls, a => navigate.execute(a, exec), args);
  }
});

test('scroll accepts only up or down and nothing else', async () => {
  const { tool, calls, exec } = await setup();
  const scroll = tool('browser_scroll');
  for (const args of [{}, { direction: 'left' }, { direction: 'UP' }, { direction: 'up', n: 2 }, { direction: 1 }]) {
    await assertRejectedBeforeConnect(calls, a => scroll.execute(a, exec), args);
  }
});

test('click and hover reject malformed and out-of-range references', async () => {
  const { tool, calls, exec } = await setup();
  for (const name of ['browser_click', 'browser_hover']) {
    const item = tool(name);
    for (const args of [{}, { ref: '' }, { ref: 'E1' }, { ref: 'e01a' }, { ref: 'e1;x' },
      { ref: 'e80' }, { ref: 'e999' }, { ref: 3 }, { ref: 'e0', extra: 1 }]) {
      await assertRejectedBeforeConnect(calls, a => item.execute(a, exec), args);
    }
  }
});

test('fill and type reject bad references, oversized text and control characters', async () => {
  const { tool, calls, exec } = await setup();
  for (const name of ['browser_fill', 'browser_type']) {
    const item = tool(name);
    const bad = [
      {}, { ref: 'e0' }, { ref: 'e80', text: 'a' }, { ref: 'e0', text: 42 },
      { ref: 'e0', text: 'a'.repeat(600) },
      { ref: 'e0', text: 'line\u0000break' },
      { ref: 'e0', text: 'x', extra: 1 }
    ];
    for (const args of bad) {
      await assertRejectedBeforeConnect(calls, a => item.execute(a, exec), args);
    }
  }
});

test('press accepts only the fixed key whitelist', async () => {
  const { tool, calls, exec } = await setup();
  const press = tool('browser_press');
  for (const args of [{}, { key: 'F5' }, { key: 'enter' }, { key: 'A' }, { key: 'Enter', extra: 1 }]) {
    await assertRejectedBeforeConnect(calls, a => press.execute(a, exec), args);
  }
});

test('select requires a reference and a value', async () => {
  const { tool, calls, exec } = await setup();
  const select = tool('browser_select');
  for (const args of [{}, { ref: 'e0' }, { value: 'us' }, { ref: 'e80', value: 'us' },
    { ref: 'e0', value: 'a'.repeat(600) }]) {
    await assertRejectedBeforeConnect(calls, a => select.execute(a, exec), args);
  }
});

test('text rejects negative, fractional, oversized or extra window fields', async () => {
  const { tool, calls, exec } = await setup();
  const text = tool('browser_text');
  const bad = [
    { offset: -1 }, { offset: 1.5 }, { offset: 200001 }, { limit: 0 }, { limit: 8001 },
    { limit: 1.5 }, { offset: 0, limit: 10, extra: 1 }, { offset: '0' }
  ];
  for (const args of bad) {
    await assertRejectedBeforeConnect(calls, a => text.execute(a, exec), args);
  }
});

test('valid arguments are normalised before they reach the relay', async () => {
  const { tool, calls, exec } = await setup();
  await tool('browser_open').execute({ url: 'https://example.test' }, exec);
  const openCall = calls.find(call => call[0] === 'request');
  assert.equal(openCall[2].url, 'https://example.test/', 'URL is canonicalised');

  calls.length = 0;
  await tool('browser_text').execute({}, exec);
  const textCall = calls.find(call => call[0] === 'request');
  assert.equal(textCall[2].offset, 0);
  assert.equal(textCall[2].limit, 4000, 'defaults are applied, not passed through as undefined');

  calls.length = 0;
  await tool('browser_fill').execute({ ref: 'e3', text: 'hello' }, exec);
  const fillCall = calls.find(call => call[0] === 'request');
  assert.equal(fillCall[2].ref, 'e3');
  assert.equal(typeof fillCall[2].text, 'string');
  assert.notEqual(fillCall[2].text, 'hello', 'text travels encoded, never verbatim');
  assert.equal(Buffer.from(fillCall[2].text, 'base64').toString('utf8'), 'hello');

  calls.length = 0;
  await tool('browser_select').execute({ ref: 'e2', value: 'us' }, exec);
  const selectCall = calls.find(call => call[0] === 'request');
  assert.equal(Buffer.from(selectCall[2].text, 'base64').toString('utf8'), 'us');
});

test('a rejected argument never reaches the credential provider either', async () => {
  const { registerRelayTools } = await import(path.join(plugin, 'index.js'));
  const agent = { id: 'session-no-credentials' };
  const defs = [];
  let credentialsRequested = 0;
  const ctx = {
    agents: { get: id => (id === agent.id ? agent : undefined) },
    tools: { register: definition => defs.push(definition) },
    harmonyBrowserRelay: {
      async getCredentials() { credentialsRequested++; return { host: '127.0.0.1', port: 1, credential: 'x' }; }
    }
  };
  let connects = 0;
  registerRelayTools(ctx, definition => definition, async () => { connects++; return { request: async () => ({ ok: true, value: '' }), close() {} }; });
  const signal = new AbortController().signal;
  await assert.rejects(defs.find(d => d.name === 'browser_open').execute({ url: 'file:///x' }, { agent, signal }));
  assert.equal(credentialsRequested, 0, 'forbidden requests must not even fetch credentials');
  assert.equal(connects, 0);
});

// --- audit integration ---------------------------------------------------

async function auditSetup(connect) {
  const { registerRelayTools } = await import(path.join(plugin, 'index.js'));
  const agent = { id: 'session-audit' };
  const defs = [];
  const ctx = {
    agents: { get: id => (id === agent.id ? agent : undefined) },
    tools: { register: definition => defs.push(definition) },
    harmonyBrowserRelay: { async getCredentials() { return { host: '127.0.0.1', port: 1, credential: 'a'.repeat(64) }; } }
  };
  registerRelayTools(ctx, definition => definition, connect);
  return { agent, defs, signal: new AbortController().signal };
}

function withHome(run) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-audit-int-'));
  const prior = process.env.DSH_HOME;
  process.env.DSH_HOME = dir;
  const done = () => {
    if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior;
    fs.rmSync(dir, { recursive: true, force: true });
  };
  return Promise.resolve().then(() => run(path.join(dir, 'browser-audit.jsonl'))).finally(done);
}

const readLines = file => fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];

test('a forbidden request is audited with its reason and never connects', async () => {
  await withHome(async file => {
    let connects = 0;
    const { agent, defs, signal } = await auditSetup(async () => { connects++; return { request: async () => ({ ok: true, value: '' }), close() {} }; });
    await assert.rejects(defs.find(d => d.name === 'browser_open').execute({ url: 'file:///etc/passwd' }, { agent, signal }));
    assert.equal(connects, 0);
    const lines = readLines(file);
    assert.equal(lines.length, 1, 'the attempt is recorded even though it never reached the policy layer');
    assert.equal(lines[0].operation, 'open');
    assert.equal(lines[0].outcome, 'invalid');
    assert.equal(lines[0].code, 'invalid_arguments');
    assert.equal(JSON.stringify(lines).includes('passwd'), false, 'the rejected URL is not copied into the log');
  });
});

test('a transport failure is audited as error or unknown, not as success', async () => {
  await withHome(async file => {
    const { agent, defs, signal } = await auditSetup(async () => ({
      async request() { throw Object.assign(new Error('gone'), { code: 'unknown' }); },
      close() {}
    }));
    await assert.rejects(defs.find(d => d.name === 'browser_observe').execute({}, { agent, signal }));
    const lines = readLines(file);
    assert.equal(lines.length, 1);
    assert.equal(lines[0].outcome, 'unknown');
    assert.equal(lines[0].code, 'unknown');
  });
});

test('a successful request is audited as ok without page content', async () => {
  await withHome(async file => {
    const { agent, defs, signal } = await auditSetup(async () => ({
      async request() { return { ok: true, value: JSON.stringify({ text: 'SECRET PAGE BODY', total: 16 }) }; },
      close() {}
    }));
    const out = await defs.find(d => d.name === 'browser_text').execute({ offset: 0, limit: 100 }, { agent, signal });
    assert.match(out, /UNTRUSTED/);
    const lines = readLines(file);
    assert.equal(lines.length, 1);
    assert.equal(lines[0].outcome, 'ok');
    assert.equal(lines[0].offset, 0);
    assert.equal(lines[0].limit, 100);
    assert.equal(fs.readFileSync(file, 'utf8').includes('SECRET PAGE BODY'), false,
      'the audit trail must never contain page text');
  });
});

test('entered text is audited only as a byte length', async () => {
  await withHome(async file => {
    const { agent, defs, signal } = await auditSetup(async () => ({
      async request() { return { ok: true, value: 'filled' }; }, close() {}
    }));
    await defs.find(d => d.name === 'browser_fill').execute({ ref: 'e0', text: 'hunter2' }, { agent, signal });
    const raw = fs.readFileSync(file, 'utf8');
    assert.equal(raw.includes('hunter2'), false, 'typed secrets must never reach the audit log');
    const line = readLines(file)[0];
    assert.equal(line.textLength, 7);
    assert.equal(line.ref, 'e0');
  });
});
