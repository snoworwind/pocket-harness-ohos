'use strict';
// Approval-time races on the native side.
//
// BrowserBridge must re-validate the session, page and binding generation
// *after* the user approves, because the approval dialog can stay open while
// the world moves underneath it. These tests drive the real relay and the
// transpiled ArkTS bridge, and change the world from inside authorize().
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawn } = require('node:child_process');
const ts = require('typescript');

const root = path.join(__dirname, '..');
const at = relative => path.join(root, relative);

function load(file, modules) {
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, {
    module, exports: module.exports, setTimeout, clearTimeout,
    require(name) {
      if (!(name in modules)) throw new Error('Unexpected import ' + name);
      return modules[name];
    }
  });
  return module.exports;
}

const browserScripts = load(at('entry/src/main/ets/pages/BrowserObserveScript.ets'), {});
const { BrowserRelay } = load(at('entry/src/main/ets/platform/BrowserRelay.ets'), {
  '@kit.ArkTS': { url: { URL } }, '../pages/BrowserObserveScript': browserScripts
});
const { BrowserBridge } = load(at('entry/src/main/ets/platform/BrowserBridge.ets'), {
  './BrowserRelay': { BrowserRelay }, '../pages/BrowserObserveScript': browserScripts
});

async function harness(t, options = {}) {
  const { registerRelayTools } = await import(path.join(root, 'plugins/dsh-harmony-browser/index.js'));
  const { createCredentialProvider } = await import(path.join(root, 'plugins/dsh-harmony-browser/credential-provider.js'));

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-bridge-guard-'));
  const home = path.join(dir, 'home');
  fs.mkdirSync(home, { mode: 0o700 });
  const prior = process.env.DSH_HOME;
  process.env.DSH_HOME = home;

  const agent = { id: 'session-guard-test' };
  const definitions = [];
  const actions = [];
  const approvals = [];
  const ctx = { agents: { get: id => (id === agent.id ? agent : undefined) }, tools: { register: d => definitions.push(d) } };
  registerRelayTools(ctx, d => d, undefined, createCredentialProvider(ctx));

  const state = {
    session: agent.id,
    title: 'Page',
    url: 'https://example.test/',
    generation: 1
  };

  let processHandle;
  let readyResolve;
  const ready = new Promise(resolve => { readyResolve = resolve; });
  const runtime = {
    startBrowserRelay(output, exit) {
      const child = spawn(process.execPath, ['--jitless', path.resolve(root, 'plugins/dsh-harmony-browser/relay.cjs'), '--publish-ready'],
        { env: { ...process.env, DSH_HOME: home }, stdio: ['pipe', 'pipe', 'pipe'] });
      processHandle = child;
      child.stderr.resume();
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', output);
      child.stdin.on('error', () => {});
      child.on('exit', code => exit(code ?? -1));
      return {
        write: text => new Promise((resolve, reject) => child.stdin.write(text, error => (error ? reject(error) : resolve()))),
        close: () => child.kill()
      };
    }
  };

  const control = {
    currentGeneration: () => state.generation,
    consumeRebind() {},
    observe: () => ({ generation: state.generation, title: state.title, url: state.url }),
    scroll(generation, direction) { actions.push({ generation, direction }); },
    click(generation, ref) { actions.push({ generation, ref }); return 'clicked'; }
  };

  const bridge = new BrowserBridge(runtime, control, {
    visibleSessionId: () => state.session,
    authorize: async details => {
      approvals.push(details);
      if (options.duringApproval) options.duringApproval(state);
      return options.allow !== false;
    },
    deliverReady: async () => { readyResolve(); }
  });

  t.after(() => {
    try { bridge.stop(); } finally {
      processHandle?.kill();
      if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  bridge.start();
  await ready;
  const tool = name => definitions.find(d => d.name === name);
  const signal = new AbortController().signal;
  return { state, actions, approvals, tool, signal, agent };
}

test('a session switch during approval cancels the action', async t => {
  const h = await harness(t, { duringApproval: state => { state.session = 'another-session'; } });
  await assert.rejects(h.tool('browser_scroll').execute({ direction: 'down' }, { agent: h.agent, signal: h.signal }),
    /no automatic retry|UNKNOWN/);
  assert.deepEqual(h.actions, [], 'the scroll must not reach the page after the session changed');
  assert.equal(h.approvals.length, 1, 'the dialog was shown once, then invalidated');
});

test('a page change during approval cancels the action', async t => {
  const h = await harness(t, { duringApproval: state => { state.url = 'https://evil.test/'; } });
  await assert.rejects(h.tool('browser_scroll').execute({ direction: 'up' }, { agent: h.agent, signal: h.signal }),
    /no automatic retry|UNKNOWN/);
  assert.deepEqual(h.actions, [], 'a scroll approved for one page must not run on another');
});

test('a title change during approval cancels the action', async t => {
  const h = await harness(t, { duringApproval: state => { state.title = 'Totally different page'; } });
  await assert.rejects(h.tool('browser_click').execute({ ref: 'e0' }, { agent: h.agent, signal: h.signal }),
    /no automatic retry|UNKNOWN/);
  assert.deepEqual(h.actions, [], 'title is part of the approved page identity');
});

test('a rebind during approval cancels the action', async t => {
  const h = await harness(t, { duringApproval: state => { state.generation += 1; } });
  await assert.rejects(h.tool('browser_scroll').execute({ direction: 'down' }, { agent: h.agent, signal: h.signal }),
    /no automatic retry|UNKNOWN/);
  assert.deepEqual(h.actions, [], 'a new browser binding invalidates the approval');
});

test('each request needs its own approval and runs exactly once', async t => {
  const h = await harness(t);
  const scroll = h.tool('browser_scroll');
  await scroll.execute({ direction: 'down' }, { agent: h.agent, signal: h.signal });
  await scroll.execute({ direction: 'up' }, { agent: h.agent, signal: h.signal });
  assert.equal(h.approvals.length, 2, 'no approval is reused between requests');
  assert.deepEqual(h.actions.map(a => a.direction), ['down', 'up'], 'each approved request runs once');
});

test('a refused approval produces no side effect and no retry', async t => {
  const h = await harness(t, { allow: false });
  await assert.rejects(h.tool('browser_click').execute({ ref: 'e1' }, { agent: h.agent, signal: h.signal }),
    /no automatic retry|UNKNOWN/);
  assert.deepEqual(h.actions, []);
  assert.equal(h.approvals.length, 1);
});
