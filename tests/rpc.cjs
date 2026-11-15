// OfficialRpc 的协议行为测试：帧格式、事件映射、审批三态与坏帧容忍。
const test = require('node:test');
const assert = require('node:assert');
const { OfficialRpc } = require('../.test-build/OfficialRpc.js');

function harness(hooks) {
  const written = [];
  const pipe = {
    write(line) { written.push(line); return Promise.resolve(); },
    close() { pipe.closed = true; },
    closed: false,
  };
  const events = [];
  const cancelled = [];
  const merged = Object.assign({
    event: (event) => events.push(event),
    approval: () => Promise.resolve(true),
    question: () => Promise.resolve({ answers: [] }),
    cancelled: (id) => cancelled.push(id),
  }, hooks || {});
  const rpc = new OfficialRpc(pipe, merged);
  return { rpc, pipe, written, events, cancelled };
}

function lastFrame(written) {
  return JSON.parse(written[written.length - 1]);
}

test('request 使用换行分隔的 JSON-RPC 2.0', () => {
  const { rpc, written } = harness();
  rpc.request('initialize', { cwd: '/data' }, 0);
  assert.strictEqual(written.length, 1);
  assert.ok(written[0].endsWith('\n'));
  const frame = JSON.parse(written[0]);
  assert.deepStrictEqual(Object.keys(frame).sort(), ['id', 'jsonrpc', 'method', 'params']);
  assert.strictEqual(frame.jsonrpc, '2.0');
  assert.strictEqual(frame.method, 'initialize');
  assert.strictEqual(frame.id, 1);
});

test('非 ASCII 参数按 \\u 转义发送，字节与字符偏移一致', () => {
  const { rpc, written } = harness();
  rpc.request('session/prompt', { text: '计划 ✓' }, 0);
  const raw = written[0];
  assert.ok(!/[^\x00-\x7f]/.test(raw.slice(0, -1)));
  assert.strictEqual(JSON.parse(raw).params.text, '计划 ✓');
});

test('响应按 id 解决对应请求', async () => {
  const { rpc } = harness();
  const pending = rpc.request('session/wait', { sessionId: 's' }, 0);
  rpc.receive('{"jsonrpc":"2.0","id":1,"result":{"status":"idle"}}\n');
  assert.deepStrictEqual(await pending, { status: 'idle' });
});

test('坏帧被忽略，后续帧仍然处理', async () => {
  const { rpc, events } = harness();
  const pending = rpc.request('session/wait', { sessionId: 's' }, 0);
  rpc.receive('{not json}\n');
  rpc.receive('{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n');
  assert.deepStrictEqual(await pending, { ok: true });
  rpc.receive('{"jsonrpc":"2.0","method":"session.status","params":{"sessionId":"s","status":"running"}}\n');
  assert.strictEqual(events.length, 1);
  assert.strictEqual(events[0].kind, 'session.status');
  assert.strictEqual(events[0].text, 'running');
});

test('assistant/message 与 tool/call 事件映射为界面角色', () => {
  const { rpc, events } = harness();
  rpc.receive(JSON.stringify({ jsonrpc: '2.0', method: 'session.event', params: { sessionId: 's', event: {
    type: 'assistant/message', seq: 3, data: { message: { content: [{ type: 'text', text: '好的' }] } } } } }) + '\n');
  assert.strictEqual(events[0].role, 'assistant');
  assert.strictEqual(events[0].text, '好的');
  rpc.receive(JSON.stringify({ jsonrpc: '2.0', method: 'session.event', params: { sessionId: 's', event: {
    type: 'tool/call', seq: 4, data: { name: 'bash', callId: 'c1', arguments: '{"cmd":"ls"}' } } } }) + '\n');
  assert.strictEqual(events[1].role, 'tool');
  assert.ok(events[1].text.includes('bash'));
});

test('turn/end 使用 reason.kind，不把对象当文本', () => {
  const { rpc, events } = harness();
  rpc.receive(JSON.stringify({ jsonrpc: '2.0', method: 'session.event', params: { sessionId: 's', event: {
    type: 'turn/end', seq: 5, data: { turn: 1, reason: { kind: 'completed' } } } } }) + '\n');
  assert.strictEqual(events[0].text, 'completed');
});

test('审批接受时回传 allowed-once', async () => {
  const { rpc, written } = harness({ approval: () => Promise.resolve(true) });
  rpc.receive('{"jsonrpc":"2.0","id":9,"method":"approval/request","params":{"sessionId":"s","toolName":"bash","callId":"c1","reason":"run"}}\n');
  await new Promise((resolve) => setTimeout(resolve, 10));
  const reply = lastFrame(written);
  assert.deepStrictEqual(reply.result, { outcome: 'allowed-once' });
  assert.strictEqual(reply.id, 9);
});

test('审批拒绝时回传 rejected', async () => {
  const { rpc, written } = harness({ approval: () => Promise.resolve(false) });
  rpc.receive('{"jsonrpc":"2.0","id":10,"method":"approval/request","params":{"sessionId":"s","toolName":"bash"}}\n');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepStrictEqual(lastFrame(written).result, { outcome: 'rejected' });
});

test('连接关闭时未决审批按 cancelled 结束', async () => {
  const { rpc, written, cancelled } = harness({ approval: () => new Promise(() => {}) });
  rpc.receive('{"jsonrpc":"2.0","id":11,"method":"approval/request","params":{"sessionId":"s","toolName":"bash"}}\n');
  await new Promise((resolve) => setTimeout(resolve, 10));
  rpc.dispose('引擎退出');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepStrictEqual(lastFrame(written).result, { outcome: 'cancelled' });
  assert.deepStrictEqual(cancelled, ['*']);
});

test('未知宿主请求返回 -32601，不假装成功', async () => {
  const { rpc, written } = harness();
  rpc.receive('{"jsonrpc":"2.0","id":12,"method":"host/unknown","params":{}}\n');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.strictEqual(lastFrame(written).error.code, -32601);
});

test('shutdown 先发请求再关闭连接', async () => {
  const { rpc, written, pipe } = harness();
  const done = rpc.shutdown();
  rpc.receive('{"jsonrpc":"2.0","id":1,"result":{}}\n');
  await done;
  assert.strictEqual(JSON.parse(written[0]).method, 'shutdown');
  assert.ok(pipe.closed);
});

test('user-question/ask 原样回传界面答案', async () => {
  const answer = { answers: [{ id: 'q1', selected: [] }] };
  const { rpc, written } = harness({ question: () => Promise.resolve(answer) });
  rpc.receive(JSON.stringify({ jsonrpc: '2.0', id: 13, method: 'user-question/ask',
    params: { requestId: 'r1', sessionId: 's', questions: [{ id: 'q1', question: '?' }] } }) + '\n');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepStrictEqual(lastFrame(written).result, answer);
});
