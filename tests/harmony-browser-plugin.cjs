'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('plugins/dsh-harmony-terminal/client.js', 'utf8');
assert.equal(source, fs.readFileSync('entry/src/main/resources/rawfile/tools/harmony-terminal/client.js', 'utf8'));
function run({ nonce = 'test-nonce', child = false } = {}) {
  const messages = [], effects = [], registrations = [], bodies = {}, closers = {};
  let interval;
  const element = { getBoundingClientRect: () => ({ left: 10, top: 20, width: 300, height: 400, right: 310, bottom: 420 }) };
  const React = {
    createElement: (type, props) => { if (props.ref) props.ref.current = element; return { type, props }; },
    useRef: value => ({ current: value }), useEffect: fn => effects.push(fn),
  };
  const document = { sessionId: 'session-a', visibilityState: 'visible', addEventListener() {}, removeEventListener() {},
    querySelector() { return { getAttribute: () => document.sessionId }; } };
  const window = {
    __dshNonce: nonce, innerWidth: 800, innerHeight: 600,
    addEventListener() {}, removeEventListener() {},
    setInterval(fn) { interval = fn; return 1; }, clearInterval() {},
    requestAnimationFrame() { return 2; }, cancelAnimationFrame() {},
  };
  window.top = child ? {} : window;
  window.__ModuleLoader__ = { load(module) {
    const plugin = module.factory(name => { assert.equal(name, 'react'); return React; });
    plugin.apply({ effect(fn) { fn(); },
      sidebarRightTabs: { register(value) { registrations.push(value); } },
      sidebarRight: { registerCloseHandler(kind, fn) { closers[kind] = fn; } },
      slots: { inject(name, fn) { fn(); }, register(options, component) { bodies[options.key] = component; } },
    });
  } };
  vm.runInNewContext(source, { window, document, console: { log: text => messages.push(text) } });
  const browser = registrations.find(value => value.kind === 'browser-harmony');
  assert.ok(browser); assert.equal(browser.multiple, false); assert.equal(browser.keepMounted, false);
  let closed = 0;
  bodies['harmony-native-browser']({ useTabInfo: () => ({ tab: { actions: { close() { closed++; } } } }) });
  const cleanup = effects.pop()();
  return { messages, closers, cleanup, tick: () => interval(), document, window, closed: () => closed };
}
function decoded(messages) { return messages.map(text => JSON.parse(text.slice('DSH_TERM:test-nonce:'.length))); }
const instance = run();
assert.deepEqual(decoded(instance.messages), [
  { op: 'browserOpen' },
  { op: 'browserBounds', left: 10, top: 20, width: 300, height: 400, visible: true, sessionId: 'session-a' },
]);
instance.tick(); assert.equal(instance.messages.length, 2);
instance.document.sessionId = 'session-b'; instance.tick();
assert.equal(decoded(instance.messages).at(-1).sessionId, 'session-b');
instance.document.sessionId = ''; instance.tick();
assert.equal(decoded(instance.messages).at(-1).sessionId, '');
instance.document.visibilityState = 'hidden'; instance.tick();
assert.equal(decoded(instance.messages).at(-1).visible, false);
assert.equal(typeof instance.window.__dshBrowserClosed, 'function');
instance.window.__dshBrowserClosed(); assert.equal(instance.closed(), 1);
instance.closers['browser-harmony'](); instance.cleanup();
assert.equal(instance.window.__dshBrowserClosed, undefined);
assert.deepEqual(decoded(instance.messages).slice(-2), [{ op: 'browserClose' }, { op: 'browserVisible', visible: false }]);
for (const options of [{ nonce: '' }, { child: true }]) {
  const blocked = run(options); blocked.closers['browser-harmony'](); blocked.cleanup();
  assert.deepEqual(blocked.messages, []);
}
console.log('harmony browser plugin tests passed');
