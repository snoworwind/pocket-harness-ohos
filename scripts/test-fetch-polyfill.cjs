'use strict';
// 主机侧回归测试：强制安装 fetch 补丁，对本地 HTTP 服务覆盖常用语义。
process.env.DSH_FORCE_FETCH_POLYFILL = '1';
require('../entry/src/main/resources/rawfile/harmony/fetch-polyfill.cjs');

const assert = require('node:assert');
const http = require('node:http');
const zlib = require('node:zlib');
const fs = require('node:fs');
const path = require('node:path');

const server = http.createServer((req, res) => {
  if (req.url === '/json') {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (req.url === '/echo') {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({
        method: req.method,
        ctype: req.headers['content-type'] || '',
        len: body.length,
        body: body.toString('utf8'),
      }));
    });
    return;
  }
  if (req.url === '/gzip') {
    res.setHeader('content-encoding', 'gzip');
    res.end(zlib.gzipSync('hello-gzip'));
    return;
  }
  if (req.url === '/redirect') {
    res.statusCode = 302;
    res.setHeader('location', '/json');
    res.end();
    return;
  }
  if (req.url === '/redirect302') {
    res.statusCode = 302;
    res.setHeader('location', '/echo');
    res.end();
    return;
  }
  if (req.url === '/redirect303') {
    res.statusCode = 303;
    res.setHeader('location', '/echo');
    res.end();
    return;
  }
  if (req.url === '/sse') {
    res.setHeader('content-type', 'text/event-stream');
    res.write('data: 1\n\n');
    setTimeout(() => { res.write('data: 2\n\n'); res.end(); }, 80);
    return;
  }
  if (req.url === '/slow') {
    setTimeout(() => res.end('late'), 3000);
    return;
  }
  if (req.url === '/204') {
    res.statusCode = 204;
    res.end();
    return;
  }
  if (req.url === '/205') {
    // 205 也必须按空 body 处理：旧实现把它当有 body，Response 构造器抛
    // TypeError，而异常发生在异步回调里，会直接终止引擎进程。
    res.statusCode = 205;
    res.end('this body must be ignored');
    return;
  }
  if (req.url === '/bad-status') {
    // 不可表示的状态码：Response 构造器会抛错，fetch 必须 reject 而不是崩掉。
    res.statusCode = 700;
    res.end('bad');
    return;
  }
  if (req.url === '/head') {
    res.end('ignored');
    return;
  }
  res.statusCode = 404;
  res.end();
});

function pass(name) { console.log('PASS', name); }

(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    // 1. GET JSON
    let r = await fetch(base + '/json');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.url, base + '/json');
    assert.strictEqual(r.type, 'basic');
    assert.deepStrictEqual(await r.json(), { ok: true });
    pass('GET JSON');

    // 2. POST JSON
    r = await fetch(base + '/echo', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ a: 1 }),
    });
    let data = await r.json();
    assert.strictEqual(data.method, 'POST');
    assert.strictEqual(data.ctype, 'application/json');
    assert.strictEqual(data.body, '{"a":1}');
    pass('POST JSON');

    // 3. gzip
    r = await fetch(base + '/gzip');
    assert.strictEqual(await r.text(), 'hello-gzip');
    pass('gzip decode');

    // 4. redirect follow (302)
    r = await fetch(base + '/redirect');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.redirected, true);
    assert.strictEqual(r.url, base + '/json');
    pass('redirect follow');

    // 5. redirect + POST 302 → GET
    r = await fetch(base + '/redirect302', { method: 'POST', body: 'x' });
    data = await r.json();
    assert.strictEqual(data.method, 'GET');
    pass('302 POST → GET');

    // 6. redirect 303 → GET
    r = await fetch(base + '/redirect303', { method: 'POST', body: 'x' });
    data = await r.json();
    assert.strictEqual(data.method, 'GET');
    pass('303 → GET');

    // 7. redirect: error
    await assert.rejects(fetch(base + '/redirect', { redirect: 'error' }), TypeError);
    pass('redirect error');

    // 8. redirect: manual
    r = await fetch(base + '/redirect', { redirect: 'manual' });
    assert.strictEqual(r.status, 302);
    pass('redirect manual');

    // 9. FormData（文本 + Blob）
    const form = new FormData();
    form.append('name', 'dsh');
    form.append('file', new Blob(['hello'], { type: 'text/plain' }), 'a.txt');
    r = await fetch(base + '/echo', { method: 'POST', body: form });
    data = await r.json();
    assert.match(data.ctype, /^multipart\/form-data; boundary=/);
    assert.match(data.body, /name="name"\r\n\r\ndsh/);
    assert.match(data.body, /filename="a.txt"/);
    assert.match(data.body, /hello/);
    pass('FormData upload');

    // 10. Blob body
    r = await fetch(base + '/echo', { method: 'POST', body: new Blob(['blob-body'], { type: 'text/plain' }) });
    data = await r.json();
    assert.strictEqual(data.ctype, 'text/plain');
    assert.strictEqual(data.body, 'blob-body');
    pass('Blob body');

    // 11. ReadableStream 请求体
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('stream-body'));
        controller.close();
      },
    });
    r = await fetch(base + '/echo', { method: 'POST', body: stream, duplex: 'half' });
    data = await r.json();
    assert.strictEqual(data.body, 'stream-body');
    pass('ReadableStream body');

    // 12. SSE 流式
    r = await fetch(base + '/sse');
    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let text = '';
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      text += decoder.decode(chunk.value, { stream: true });
    }
    assert.match(text, /data: 1/);
    assert.match(text, /data: 2/);
    pass('SSE streaming');

    // 13. 204 body === null
    r = await fetch(base + '/204');
    assert.strictEqual(r.status, 204);
    assert.strictEqual(r.body, null);
    pass('204 null body');

    // 13b. 205 body === null（issue #2 回归）
    r = await fetch(base + '/205');
    assert.strictEqual(r.status, 205);
    assert.strictEqual(r.body, null);
    assert.strictEqual(await r.text(), '');
    pass('205 null body');

    // 13c. 状态码无法构造 Response 时，fetch 以 TypeError 拒绝而不是未捕获异常
    await assert.rejects(fetch(base + '/bad-status'), TypeError);
    pass('invalid status rejects');

    // 13d. 纯函数层面的无 body 判定（HEAD/204/205/304）
    const internals = globalThis.__dshFetchPolyfillInternals;
    assert.strictEqual(internals.isNullBodyStatus('HEAD', 200), true);
    assert.strictEqual(internals.isNullBodyStatus('GET', 204), true);
    assert.strictEqual(internals.isNullBodyStatus('GET', 205), true);
    assert.strictEqual(internals.isNullBodyStatus('GET', 304), true);
    assert.strictEqual(internals.isNullBodyStatus('GET', 200), false);
    pass('null-body status predicate');

    // 14. HEAD body === null
    r = await fetch(base + '/head', { method: 'HEAD' });
    assert.strictEqual(r.body, null);
    pass('HEAD null body');

    // 15. AbortSignal → AbortError
    const controller = new AbortController();
    const pending = fetch(base + '/slow', { signal: controller.signal });
    setTimeout(() => controller.abort(), 50);
    await assert.rejects(pending, (error) => error.name === 'AbortError');
    pass('abort');

    // 16. undici 的 fetch 导出应被换成补丁实现（dsh-web-fetch-http 不走全局 fetch）
    const fixtureRoot = fs.mkdtempSync(path.join(__dirname, '.tmp-undici-'));
    try {
      const undiciDir = path.join(fixtureRoot, 'undici');
      fs.mkdirSync(undiciDir);
      const undiciEntry = path.join(undiciDir, 'index.js');
      fs.writeFileSync(undiciEntry, 'exports.fetch = function nativeFetch() { return "native"; };\nexports.Agent = function Agent() {};\n');
      const fakeUndici = require(undiciEntry);
      assert.strictEqual(fakeUndici.fetch, globalThis.fetch, 'undici.fetch 应指向补丁实现');
      assert.strictEqual(typeof fakeUndici.Agent, 'function', 'undici 的其它导出应保持原样');
      const res = await fakeUndici.fetch(base + '/json', { redirect: 'manual', headers: { 'user-agent': 'x' } });
      assert.strictEqual(res.status, 200);
      assert.deepStrictEqual(await res.json(), { ok: true });
      pass('undici fetch override');
    } finally {
      fs.rmSync(fixtureRoot, { recursive: true, force: true });
    }

    console.log('ALL PASS');
  } finally {
    server.close();
  }
})().catch((error) => {
  console.error('FAIL', error);
  process.exitCode = 1;
});
