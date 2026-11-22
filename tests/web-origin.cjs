'use strict';
// 宿主测试：Web 服务端口候选与 URL 解析。
// 端口决定 localStorage 的 origin，这里锁住「优先复用上次端口、被占用才顺延、
// 最后退回 0」的顺序，避免以后改成随机端口又把上次会话/设置弄丢。
const test = require('node:test');
const assert = require('node:assert/strict');
const { isUsableWebPort, isWebPortInUse, webPortCandidates, webPortFromUrl } =
  require('../.test-build/WebOrigin');

test('candidates reuse the saved port first, then walk the base range, then 0', () => {
  const plan = webPortCandidates(17431, 17431, 3);
  assert.deepEqual(plan, [17431, 17432, 17433, 0]);
  const other = webPortCandidates(20000, 17431, 3);
  assert.deepEqual(other, [20000, 17431, 17432, 17433, 0]);
});

test('candidates drop invalid saved values and stay unique', () => {
  for (const saved of [0, 80, 70000, -1, 1.5, NaN]) {
    const plan = webPortCandidates(saved, 17431, 2);
    assert.deepEqual(plan, [17431, 17432, 0]);
  }
  assert.deepEqual(webPortCandidates(17432, 17431, 2), [17432, 17431, 0]);
});

test('candidates never exceed the usable port range', () => {
  const plan = webPortCandidates(65534, 65534, 5);
  assert.deepEqual(plan, [65534, 65535, 0]);
  assert.ok(plan.every((port) => port === 0 || isUsableWebPort(port)));
});

test('webPortFromUrl reads the printed loopback URL', () => {
  assert.equal(webPortFromUrl('http://127.0.0.1:53877/?token=abc'), 53877);
  assert.equal(webPortFromUrl('http://localhost:17431/'), 17431);
  assert.equal(webPortFromUrl('http://127.0.0.1/'), 0);
  assert.equal(webPortFromUrl('http://127.0.0.1:80/'), 0);
  assert.equal(webPortFromUrl('not a url'), 0);
});

test('only address-in-use failures are retried on another port', () => {
  assert.equal(isWebPortInUse('Error: listen EADDRINUSE: address already in use 127.0.0.1:17431'), true);
  assert.equal(isWebPortInUse('failed to listen on 127.0.0.1:17431'), true);
  assert.equal(isWebPortInUse('端口被占用'), true);
  assert.equal(isWebPortInUse('Cannot find module "@local/plugin"'), false);
  assert.equal(isWebPortInUse('configuration entry is no longer available'), false);
});
