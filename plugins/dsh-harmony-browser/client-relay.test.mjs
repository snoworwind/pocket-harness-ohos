import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import net from 'node:net';
import { connectRelay } from './client-relay.js';

async function relay(t) {
  const child = spawn(process.execPath, [new URL('./relay.cjs', import.meta.url).pathname], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stderr.resume();
  const lines = createInterface({ input: child.stdout });
  const queue = [], waiters = [];
  lines.on('line', line => { const obj = JSON.parse(line); const waiter = waiters.shift(); if (waiter) waiter(obj); else queue.push(obj); });
  const next = () => queue.length ? Promise.resolve(queue.shift()) : new Promise(resolve => waiters.push(resolve));
  t.after(() => { child.kill(); lines.close(); });
  return { child, next, ready: { ...await next(), sessionId: 'test_session' }, reply: obj => child.stdin.write(JSON.stringify(obj) + '\n') };
}

test('real relay requires credential and returns native authorization decisions', async t => {
  const r = await relay(t);
  await assert.rejects(connectRelay({ ...r.ready, credential: '0'.repeat(64) }));
  const client = await connectRelay(r.ready); t.after(() => client.close());
  const denied = client.request('open', { url: 'https://example.com/' });
  const first = await r.next(); assert.equal(first.operation, 'open'); assert.equal(first.sessionId, 'test_session');
  r.reply({ type: 'result', id: first.id, ok: false, error: 'denied by host' });
  assert.deepEqual(await denied, { type: 'result', id: first.id, ok: false, error: 'denied by host' });
  const allowed = client.request('observe');
  const second = await r.next(); assert.equal(second.operation, 'observe'); assert.notEqual(first.id, second.id);
  r.reply({ type: 'result', id: second.id, ok: true, value: 'authorized' });
  assert.equal((await allowed).value, 'authorized');
  client.close();
  const other = await connectRelay(r.ready); t.after(() => other.close());
  const next = other.request('observe'); const third = await r.next();
  r.reply({ type: 'result', id: third.id, ok: true, value: 'still alive' });
  assert.equal((await next).value, 'still alive');
});

test('single concurrency, validation, abort and disconnect are fail-closed', async t => {
  const r = await relay(t); const client = await connectRelay(r.ready);
  await assert.rejects(client.request('open', { url: 'https://user:pass@example.com/' }), { code: 'invalid_request' });
  const controller = new AbortController();
  const work = client.request('observe', { signal: controller.signal });
  await r.next(); await assert.rejects(client.request('observe'), { code: 'busy' });
  controller.abort(); await assert.rejects(work, { code: 'unknown' });
  await assert.rejects(client.request('observe'), { code: 'closed' });
});

test('relay busy response is definitive across authenticated clients', async t => {
  const r = await relay(t); const a = await connectRelay(r.ready); const b = await connectRelay(r.ready);
  t.after(() => { a.close(); b.close(); });
  const work = a.request('observe'); const request = await r.next();
  await assert.rejects(b.request('observe'), { code: 'busy' });
  r.reply({ type: 'result', id: request.id, ok: true, value: 'done' });
  assert.equal((await work).value, 'done');
});

test('relay exit during work means unknown, not failure or retry', async t => {
  const r = await relay(t); const client = await connectRelay(r.ready);
  const work = client.request('observe'); await r.next();
  r.child.kill(); await assert.rejects(work, { code: 'unknown' });
});

test('sends a receipt only after validating a result', async t => {
  let receiptResolve; const receipt = new Promise(resolve => { receiptResolve = resolve; });
  const server = net.createServer(socket => {
    const lines = createInterface({ input: socket }); let n = 0;
    lines.on('line', line => {
      const frame = JSON.parse(line);
      if (n++ === 0) socket.write('{"type":"ready","version":1}\n');
      else if (frame.type === 'request') socket.write(JSON.stringify({ type: 'result', id: frame.id, ok: true, value: 'ok' }) + '\n');
      else { receiptResolve(frame); socket.write(JSON.stringify({ type: 'received', id: frame.id }) + '\n'); }
    });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => server.close());
  const client = await connectRelay({ host: '127.0.0.1', port: server.address().port, credential: 'a'.repeat(64), sessionId: 'test_session' });
  t.after(() => client.close());
  const result = await client.request('observe');
  assert.deepEqual(await receipt, { type: 'receipt', id: result.id });
});

test('unconfirmed receipt remains busy and disconnect is unknown', async t => {
  let receiptResolve; const receipt = new Promise(resolve => { receiptResolve = resolve; });
  let peer;
  const server = net.createServer(socket => {
    peer = socket;
    const lines = createInterface({ input: socket });
    lines.on('line', line => {
      const frame = JSON.parse(line);
      if (frame.type === 'hello') socket.write('{"type":"ready","version":1}\n');
      else if (frame.type === 'request') socket.write(JSON.stringify({ type: 'result', id: frame.id, ok: true, value: 'ok' }) + '\n');
      else if (frame.type === 'receipt') receiptResolve(frame);
    });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => server.close());
  const client = await connectRelay({ host: '127.0.0.1', port: server.address().port, credential: 'a'.repeat(64), sessionId: 'test_session' });
  const work = client.request('observe'); await receipt;
  await assert.rejects(client.request('observe'), { code: 'busy' });
  peer.destroy(); await assert.rejects(work, { code: 'unknown' });
  await assert.rejects(client.request('observe'), { code: 'closed' });
});

test('received acknowledgement must match exactly', async t => {
  for (const bad of [id => ({ type: 'received', id: id + 'x' }), id => ({ type: 'received', id, extra: true }), id => ({ type: 'result', id, ok: true, value: 'duplicate' })]) {
    const server = net.createServer(socket => {
      const lines = createInterface({ input: socket });
      lines.on('line', line => {
        const frame = JSON.parse(line);
        if (frame.type === 'hello') socket.write('{"type":"ready","version":1}\n');
        else if (frame.type === 'request') socket.write(JSON.stringify({ type: 'result', id: frame.id, ok: true, value: 'ok' }) + '\n');
        else if (frame.type === 'receipt') socket.write(JSON.stringify(bad(frame.id)) + '\n');
      });
    });
    server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => server.close());
    const client = await connectRelay({ host: '127.0.0.1', port: server.address().port, credential: 'a'.repeat(64), sessionId: 'test_session' });
    await assert.rejects(client.request('observe'), { code: 'unknown' });
  }
});

test('strict response parsing rejects malformed and oversized frames', async t => {
  const server = net.createServer(socket => {
    socket.once('data', () => { socket.write('{"type":"ready","version":1}\n'); socket.once('data', () => socket.write('x'.repeat(131073))); });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => server.close());
  const client = await connectRelay({ host: '127.0.0.1', port: server.address().port, credential: 'a'.repeat(64), sessionId: 'test_session' });
  await assert.rejects(client.request('observe'), { code: 'unknown' });
});

 test('real relay forwards exact scroll frames and rejects extra arguments', async t => {
  const r = await relay(t); const client = await connectRelay(r.ready); t.after(() => client.close());
  for (const options of [{}, {direction:'left'}, {direction:'up',pixels:10}, {direction:'down',script:'alert(1)'}, {direction:'up',url:'https://example.com'}])
    await assert.rejects(client.request('scroll', options), {code:'invalid_request'});
  for (const direction of ['up', 'down']) {
    const work = client.request('scroll', {direction}); const frame = await r.next();
    assert.deepEqual(frame, {type:'request',id:frame.id,sessionId:'test_session',operation:'scroll',direction});
    r.reply({type:'result',id:frame.id,ok:true,value:'submitted'}); assert.equal((await work).value, 'submitted');
  }
});

test('scroll cancellation trips the real relay circuit', async t => {
  const r = await relay(t); const client = await connectRelay(r.ready); const controller = new AbortController();
  const work = client.request('scroll', {direction:'down',signal:controller.signal}); await r.next(); controller.abort();
  await assert.rejects(work, {code:'unknown'}); await assert.rejects(client.request('scroll', {direction:'up'}), {code:'closed'});
});

test('answers approval checks from the trusted resolver only', async t => {
  for (const [resolver, expected] of [[() => true, true], [() => false, false], [() => { throw Error('boom'); }, false], [undefined, false], [() => 'yes', false]]) {
    const frames = [];
    let accepted;
    const server = net.createServer(socket => {
      accepted = socket;
      const lines = createInterface({ input: socket }); let n = 0;
      lines.on('line', line => {
        const frame = JSON.parse(line); frames.push(frame);
        if (n++ === 0) return socket.write('{"type":"ready","version":1}\n');
        if (frame.type === 'request') socket.write(JSON.stringify({ type: 'policy-check', id: frame.id }) + '\n');
        else if (frame.type === 'policy') socket.write(JSON.stringify({ type: 'result', id: frame.id, ok: true, value: 'ok' }) + '\n');
        else if (frame.type === 'receipt') socket.write(JSON.stringify({ type: 'received', id: frame.id }) + '\n');
      });
    });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    let client;
    try {
      client = await connectRelay({ host: '127.0.0.1', port: server.address().port, credential: 'a'.repeat(64), sessionId: 's' });
      const result = await client.request('observe', { getAutoPermission: resolver });
      const policy = frames.find(frame => frame.type === 'policy');
      assert.equal(policy.automatic, expected, String(resolver));
      assert.equal(result.value, 'ok');
    } finally {
      client?.close(); accepted?.destroy(); await new Promise(resolve => server.close(resolve));
    }
  }
});

test('a malformed or over-used approval check closes the connection', async t => {
  for (const reply of [{ type: 'policy-check', id: 'other' }, { type: 'policy-check', id: 'x', extra: 1 }]) {
    let accepted;
    const server = net.createServer(socket => {
      accepted = socket;
      const lines = createInterface({ input: socket }); let n = 0;
      lines.on('line', line => {
        const frame = JSON.parse(line);
        if (n++ === 0) return socket.write('{"type":"ready","version":1}\n');
        if (frame.type === 'request') socket.write(JSON.stringify(reply.id === 'x' ? { ...reply, id: frame.id } : reply) + '\n');
      });
    });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    let client;
    try {
      client = await connectRelay({ host: '127.0.0.1', port: server.address().port, credential: 'a'.repeat(64), sessionId: 's' });
      // A protocol error ends the transport; the operation outcome is UNKNOWN.
      await assert.rejects(client.request('observe', { getAutoPermission: () => true }), { code: 'unknown' });
    } finally {
      client?.close(); accepted?.destroy(); await new Promise(resolve => server.close(resolve));
    }
  }
});

test('text requests carry a validated window and bad windows never leave the client', async t => {
  const r = await relay(t);
  const client = await connectRelay(r.ready); t.after(() => client.close());
  const pending = client.request('text', { offset: 100, limit: 500 });
  const frame = await r.next();
  assert.deepEqual(Object.keys(frame).sort(), ['id', 'limit', 'offset', 'operation', 'sessionId', 'type']);
  assert.equal(frame.operation, 'text');
  assert.equal(frame.offset, 100);
  assert.equal(frame.limit, 500);
  r.reply({ type: 'result', id: frame.id, ok: true, value: '{"text":"x","total":1,"offset":100,"truncated":false}' });
  assert.equal((await pending).ok, true);

  for (const bad of [{ offset: -1, limit: 10 }, { offset: 0, limit: 0 }, { offset: 0, limit: 9000 },
    { offset: 1.5, limit: 10 }, { offset: 0, limit: 10, extra: 1 }, { limit: 10 }, {}]) {
    await assert.rejects(client.request('text', bad), /invalid_request|Invalid/i,
      'rejects ' + JSON.stringify(bad));
  }
  // Nothing above may have been written to the relay: the next frame must be
  // the observe below, not a rejected text window.
  const sent = client.request('observe');
  const follow = await r.next();
  assert.equal(follow.operation, 'observe', 'rejected windows never occupied the wire');
  r.reply({ type: 'result', id: follow.id, ok: true, value: 'ok' });
  await sent;
});
