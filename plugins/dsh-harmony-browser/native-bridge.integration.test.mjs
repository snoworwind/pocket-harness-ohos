// Full protocol simulation on Node: real relay, provider, client and transpiled
// native bridge. The BrowserControl and native approval UI are fakes, not ArkWeb.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { spawn } from 'node:child_process';
import ts from 'typescript';
import { registerRelayTools } from './index.js';
import { createCredentialProvider } from './credential-provider.js';

function load(file, modules) {
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(js, { module, exports: module.exports, setTimeout, clearTimeout,
    require(name) { if (!(name in modules)) throw Error('Unexpected import'); return modules[name]; } });
  return module.exports;
}
const { BrowserRelay } = load('entry/src/main/ets/platform/BrowserRelay.ets', { '@kit.ArkTS': { url: { URL } } });
const { BrowserBridge } = load('entry/src/main/ets/platform/BrowserBridge.ets', { './BrowserRelay': { BrowserRelay } });
const browserSource = fs.readFileSync('entry/src/main/ets/pages/Browser.ets', 'utf8');
const controlSource = browserSource.slice(browserSource.indexOf('export interface BrowserObservation'), browserSource.indexOf('// 独立 Web 实例'));
const controlJs = ts.transpileModule(controlSource, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const controlModule = { exports: {} }; vm.runInNewContext(controlJs, { module: controlModule, exports: controlModule.exports });
const { BrowserControl } = controlModule.exports;

test('real relay dispatches scroll only after native approval and preserves direction', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-native-flow-'));
  const home = path.join(root, 'harness-home'); fs.mkdirSync(home, { mode: 0o700 });
  const prior = process.env.DSH_HOME; process.env.DSH_HOME = home;
  const agent = { id: 'session-native-test' }; const definitions = [], actions = [], approvals = [];
  let allow = false;
  const ctx = { agents: { get: id => id === agent.id ? agent : undefined }, tools: { register: d => definitions.push(d) } };
  const capability = createCredentialProvider(ctx);
  registerRelayTools(ctx, d => d, undefined, capability);
  let processHandle, readyResolve; const ready = new Promise(resolve => { readyResolve = resolve; });
  const runtime = { startBrowserRelay(output, exit) {
    const child = spawn(process.execPath, ['--jitless', path.resolve('plugins/dsh-harmony-browser/relay.cjs'), '--publish-ready'],
      { env: { ...process.env, DSH_HOME: home }, stdio: ['pipe', 'pipe', 'pipe'] });
    processHandle = child; child.stderr.resume(); child.stdout.setEncoding('utf8'); child.stdout.on('data', output);
    child.stdin.on('error', () => {}); child.on('exit', code => exit(code ?? -1));
    return { write: text => new Promise((resolve, reject) => child.stdin.write(text, error => error ? reject(error) : resolve())), close: () => child.kill() };
  } };
  const control = { currentGeneration: () => 1, consumeRebind() {},
    observe: generation => ({ generation, title: 'Page', url: 'https://example.test/' }),
    scroll(generation, direction) { actions.push({ generation, direction }); } };
  const bridge = new BrowserBridge(runtime, control, { visibleSessionId: () => agent.id,
    authorize: async details => { approvals.push(details); return allow; },
    deliverReady: async () => { readyResolve(); } });
  t.after(() => { try { bridge.stop(); } finally { processHandle?.kill(); if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior; fs.rmSync(root, { recursive: true, force: true }); } });
  bridge.start(); await ready;
  const tool = definitions.find(def => def.name === 'browser_scroll'); assert.ok(tool);
  const signal = new AbortController().signal;
  await assert.rejects(tool.execute({ direction: 'up' }, { agent, signal }), /no automatic retry/);
  assert.deepEqual(actions, []); assert.equal(approvals[0].direction, 'up');
  allow = true;
  const result = await tool.execute({ direction: 'down' }, { agent, signal });
  assert.match(result, /submitted/i); assert.deepEqual(actions, [{ generation: 1, direction: 'down' }]);
  assert.equal(approvals.length, 2); assert.equal(approvals[1].direction, 'down');
  assert.equal(approvals[1].sessionId, agent.id);
});

test('real relay requires visible-page confirmation between open and observe', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-open-flow-'));
  const home = path.join(root, 'harness-home'); fs.mkdirSync(home, { mode: 0o700 });
  const prior = process.env.DSH_HOME; process.env.DSH_HOME = home;
  const agent = { id: 'session-open-test' }, definitions = [], approvals = [];
  const ctx = { agents: { get: id => id === agent.id ? agent : undefined }, tools: { register: d => definitions.push(d) } };
  registerRelayTools(ctx, d => d, undefined, createCredentialProvider(ctx));
  let child, readyResolve; const ready = new Promise(resolve => { readyResolve = resolve; });
  const runtime = { startBrowserRelay(output, exit) {
    child = spawn(process.execPath, ['--jitless', path.resolve('plugins/dsh-harmony-browser/relay.cjs'), '--publish-ready'],
      { env: { ...process.env, DSH_HOME: home }, stdio: ['pipe', 'pipe', 'pipe'] });
    child.stderr.resume(); child.stdout.setEncoding('utf8'); child.stdout.on('data', output);
    child.stdin.on('error', () => {}); child.on('exit', code => exit(code ?? -1));
    return { write: text => new Promise((resolve, reject) => child.stdin.write(text, error => error ? reject(error) : resolve())), close: () => child.kill() };
  } };
  let currentUrl = 'about:blank', title = '';
  const control = new BrowserControl();
  control.attach(() => true, target => { control.navigationChanged(); currentUrl = target; title = 'Example'; return true; },
    () => ({ generation: 0, title, url: currentUrl }),
    async () => JSON.stringify({ items: [{ type: 'text', text: 'Visible example' }] }));
  control.setVisible(true);
  const bridge = new BrowserBridge(runtime, control, { visibleSessionId: () => agent.id,
    authorize: async details => { approvals.push(details); return true; },
    deliverReady: async () => { readyResolve(); } });
  t.after(() => { try { bridge.stop(); } finally { child?.kill(); if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior; fs.rmSync(root, { recursive: true, force: true }); } });
  bridge.start(); await ready;
  const signal = new AbortController().signal;
  const open = definitions.find(d => d.name === 'browser_open'), observe = definitions.find(d => d.name === 'browser_observe');
  const opened = await open.execute({ url: 'https://example.test/' }, { agent, signal });
  assert.match(opened, /submitted/i); assert.equal(approvals.length, 1);
  await assert.rejects(observe.execute({}, { agent, signal }), /no automatic retry/);
  assert.equal(approvals.length, 1); assert.equal(bridge.confirmCurrentPage(), false);
  control.pageBegin(currentUrl); control.pageEnd(currentUrl);
  assert.equal(bridge.confirmCurrentPage(), true);
  const observed = await observe.execute({}, { agent, signal });
  assert.match(observed, /Visible example/); assert.equal(approvals.length, 2);
  assert.equal(approvals[1].operation, 'observe');
});

test('Auto or full access skips the dialog end-to-end, other presets still ask', async t => {
  for (const [preset, expectDialog, expectAutomatic] of [['auto', false, true], ['danger-full-access', false, true], ['workspace-write', true, false], ['read-only', true, false]]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-mode-'));
    const home = path.join(root, 'harness-home'); fs.mkdirSync(home, { mode: 0o700 });
    const prior = process.env.DSH_HOME; process.env.DSH_HOME = home;
    const agent = { id: 'session-mode-test', session: { id: 'session-mode-test' } };
    const definitions = [], dialogs = [], automaticNotices = [];
    const ctx = {
      agents: { get: id => id === agent.id ? agent : undefined },
      get: name => name === 'permissionPresets' ? { current: () => preset } : undefined,
      tools: { register: d => definitions.push(d) }
    };
    registerRelayTools(ctx, d => d, undefined, createCredentialProvider(ctx));
    let child, readyResolve; const ready = new Promise(resolve => { readyResolve = resolve; });
    const runtime = { startBrowserRelay(output, exit) {
      child = spawn(process.execPath, ['--jitless', path.resolve('plugins/dsh-harmony-browser/relay.cjs'), '--publish-ready'],
        { env: { ...process.env, DSH_HOME: home }, stdio: ['pipe', 'pipe', 'pipe'] });
      child.stderr.resume(); child.stdout.setEncoding('utf8'); child.stdout.on('data', output);
      child.stdin.on('error', () => {}); child.on('exit', code => exit(code ?? -1));
      return { write: text => new Promise((resolve, reject) => child.stdin.write(text, error => error ? reject(error) : resolve())), close: () => child.kill() };
    } };
    const scrolls = [];
    const control = { currentGeneration: () => 1, consumeRebind() {},
      observe: generation => ({ generation, title: 'Page', url: 'https://example.test/' }),
      scroll(generation, direction) { scrolls.push(direction); } };
    const bridge = new BrowserBridge(runtime, control, {
      visibleSessionId: () => agent.id,
      authorize: async details => { dialogs.push(details); return true; },
      automaticApproved: details => { automaticNotices.push(details); },
      deliverReady: async () => { readyResolve(); } });
    try {
      bridge.start(); await ready;
      const tool = definitions.find(d => d.name === 'browser_scroll');
      const result = await tool.execute({ direction: 'down' }, { agent, signal: new AbortController().signal });
      assert.match(result, /submitted/i);
      assert.equal(dialogs.length, expectDialog ? 1 : 0, preset + ' dialog');
      assert.equal(automaticNotices.length, expectAutomatic ? 1 : 0, preset + ' notice');
      assert.deepEqual(scrolls, ['down'], preset);
    } finally {
      bridge.stop(); child?.kill();
      if (prior === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = prior;
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});
