'use strict';
// M-02 回归测试：fetch 补丁跟随重定向时的凭据剥离、降级防护与协议限制。
// 独立文件，可直接 `node tests/fetch-redirect.cjs` 运行；不改 scripts/test.cjs。
process.env.DSH_FORCE_FETCH_POLYFILL = '1';
require('../entry/src/main/resources/rawfile/harmony/fetch-polyfill.cjs');

const assert = require('node:assert');
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const internals = globalThis.__dshFetchPolyfillInternals;
assert.ok(internals, '强制安装时应暴露 __dshFetchPolyfillInternals（仅测试用）');

function pass(name) { console.log('PASS', name); }

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

function closeServer(server) {
  return new Promise((resolve) => {
    server.close(() => resolve());
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
  });
}

function echoTarget(req, res) {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({
      method: req.method,
      url: req.url,
      headers: req.headers,
      body: Buffer.concat(chunks).toString('utf8'),
    }));
  });
}

function redirectTo(res, status, location) {
  res.statusCode = status;
  res.setHeader('location', location);
  res.end();
}

// 本机有没有可用的 openssl：优先 OPENSSL 环境变量，其次 PATH，最后从 git 安装目录推断。
function resolveOpenssl() {
  const candidates = [];
  if (process.env.OPENSSL) candidates.push(process.env.OPENSSL);
  candidates.push('openssl');
  const gitExec = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
  if (gitExec.status === 0 && gitExec.stdout.trim()) {
    const gitRoot = path.resolve(gitExec.stdout.trim(), '..', '..', '..');
    if (process.platform === 'win32') {
      candidates.push(path.join(gitRoot, 'usr', 'bin', 'openssl.exe'));
      candidates.push(path.join(gitRoot, 'mingw64', 'bin', 'openssl.exe'));
    }
  }
  if (process.platform !== 'win32') {
    candidates.push('/usr/bin/openssl', '/usr/local/bin/openssl');
  }
  for (const candidate of candidates) {
    try {
      if (spawnSync(candidate, ['version'], { encoding: 'utf8' }).status === 0) return candidate;
    } catch (error) {
      // 继续尝试下一个
    }
  }
  return null;
}

function createSelfSignedCert() {
  const openssl = resolveOpenssl();
  if (!openssl) return null;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-fetch-redirect-'));
  const keyPath = path.join(dir, 'key.pem');
  const certPath = path.join(dir, 'cert.pem');
  try {
    const created = spawnSync(openssl, [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath, '-out', certPath, '-days', '1',
      '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
    ], { stdio: 'ignore' });
    if (created.status !== 0 || !fs.existsSync(keyPath) || !fs.existsSync(certPath)) return null;
    return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

(async () => {
  let targetHits = 0;
  const target = http.createServer((req, res) => {
    targetHits += 1;
    echoTarget(req, res);
  });
  const targetPort = await listen(target);
  const targetBase = 'http://127.0.0.1:' + targetPort;

  const redirector = http.createServer((req, res) => {
    switch (req.url) {
      case '/echo':
        echoTarget(req, res);
        return;
      case '/same-302':
        redirectTo(res, 302, '/echo');
        return;
      case '/cross-302':
        redirectTo(res, 302, targetBase + '/echo');
        return;
      case '/cross-301-post':
        redirectTo(res, 301, targetBase + '/echo');
        return;
      case '/cross-302-post':
        redirectTo(res, 302, targetBase + '/echo');
        return;
      case '/cross-303-put':
        redirectTo(res, 303, targetBase + '/echo');
        return;
      case '/cross-307':
        redirectTo(res, 307, targetBase + '/echo');
        return;
      case '/chain/0':
      case '/chain/1':
      case '/chain/2':
      case '/chain/3':
        redirectTo(res, 302, '/chain/' + (Number(req.url.slice(-1)) + 1));
        return;
      case '/chain/4':
        redirectTo(res, 302, '/echo');
        return;
      case '/bad-file':
        redirectTo(res, 302, 'file:///etc/passwd');
        return;
      case '/bad-ftp':
        redirectTo(res, 302, 'ftp://example.test/secret');
        return;
      default:
        res.statusCode = 404;
        res.end();
    }
  });
  const redirectPort = await listen(redirector);
  const base = 'http://127.0.0.1:' + redirectPort;

  const servers = [target, redirector];
  try {
    // 0. 重定向次数上限保持 20。
    assert.strictEqual(internals.MAX_REDIRECTS, 20);
    pass('MAX_REDIRECTS remains 20');

    // 0b. 同源判定：默认端口归一化；协议/端口不同即跨源。
    assert.strictEqual(internals.isSameOrigin('http://a.test/x', 'http://a.test:80/y'), true);
    assert.strictEqual(internals.isSameOrigin('http://a.test/x', 'https://a.test/y'), false);
    assert.strictEqual(internals.isSameOrigin('http://a.test:1/x', 'http://a.test:2/y'), false);
    pass('origin comparison rules');

    // 1. 同源 302 保留授权/会话头（现有行为不能坏）。
    let res = await fetch(base + '/same-302', {
      headers: {
        authorization: 'Bearer SAME_ORIGIN_SECRET',
        cookie: 'sid=same',
        'proxy-authorization': 'Basic c2FtZQ==',
      },
    });
    let data = await res.json();
    assert.strictEqual(data.url, '/echo');
    assert.strictEqual(data.headers.authorization, 'Bearer SAME_ORIGIN_SECRET');
    assert.strictEqual(data.headers.cookie, 'sid=same');
    assert.strictEqual(data.headers['proxy-authorization'], 'Basic c2FtZQ==');
    pass('same-origin 302 keeps authorization/cookie/proxy-authorization');

    // 2. 跨端口（不同 origin）302：第二个服务收不到敏感头，Host 被改为目标主机。
    res = await fetch(base + '/cross-302', {
      headers: {
        authorization: 'Bearer CROSS_ORIGIN_SECRET',
        cookie: 'sid=cross',
        cookie2: 'sid2=cross',
        'proxy-authorization': 'Basic Y3Jvc3M=',
        host: 'victim.example',
      },
    });
    data = await res.json();
    assert.strictEqual(res.redirected, true);
    assert.strictEqual(data.url, '/echo');
    for (const name of ['authorization', 'cookie', 'cookie2', 'proxy-authorization']) {
      assert.strictEqual(data.headers[name], undefined, name + ' 不应跨源转发');
    }
    assert.strictEqual(data.headers.host, '127.0.0.1:' + targetPort, 'Host 应使用目标 origin');
    pass('cross-origin 302 strips authorization/cookie/cookie2/proxy-authorization/host');

    // 3. 301/302 POST→GET 跨源：方法改写、体丢弃，授权与请求体头都剥离。
    for (const [route, status] of [['/cross-301-post', 301], ['/cross-302-post', 302]]) {
      res = await fetch(base + route, {
        method: 'POST',
        headers: {
          authorization: 'Bearer POST_SECRET',
          cookie: 'sid=post',
          'content-type': 'application/json',
        },
        body: '{"x":1}',
      });
      data = await res.json();
      assert.strictEqual(data.method, 'GET');
      assert.strictEqual(data.body, '');
      assert.strictEqual(data.headers.authorization, undefined);
      assert.strictEqual(data.headers.cookie, undefined);
      assert.strictEqual(data.headers['content-type'], undefined);
      assert.strictEqual(data.headers['content-length'], undefined);
      pass(status + ' cross-origin POST → GET strips credentials and body headers');
    }

    // 4. 303 PUT→GET 跨源：同样剥离授权与请求体头。
    res = await fetch(base + '/cross-303-put', {
      method: 'PUT',
      headers: { authorization: 'Bearer PUT_SECRET', 'content-type': 'text/plain' },
      body: 'payload',
    });
    data = await res.json();
    assert.strictEqual(data.method, 'GET');
    assert.strictEqual(data.body, '');
    assert.strictEqual(data.headers.authorization, undefined);
    assert.strictEqual(data.headers['content-type'], undefined);
    pass('cross-origin 303 PUT → GET strips credentials and body headers');

    // 5. 307 跨源：方法与体保留（语义需要 content-type），但凭据仍必须剥离。
    res = await fetch(base + '/cross-307', {
      method: 'POST',
      headers: { authorization: 'Bearer KEEP_METHOD_SECRET', 'content-type': 'application/json' },
      body: '{"keep":true}',
    });
    data = await res.json();
    assert.strictEqual(data.method, 'POST');
    assert.strictEqual(data.body, '{"keep":true}');
    assert.strictEqual(data.headers.authorization, undefined);
    assert.strictEqual(data.headers['content-type'], 'application/json');
    pass('cross-origin 307 keeps method/body but strips authorization');

    // 6. 多跳链仍可跟完，次数上限未被改大。
    res = await fetch(base + '/chain/0');
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.redirected, true);
    data = await res.json();
    assert.strictEqual(data.url, '/echo');
    pass('multi-hop same-origin redirect chain follows');

    // 7. 非 http(s) 重定向目标被拒绝（纯函数 + 端到端）。
    assert.throws(
      () => internals.redirectPlan('http://a.test/x', 'file:///etc/passwd', 'GET', 'GET'),
      (error) => error instanceof TypeError && /unsupported protocol/.test(error.message),
    );
    assert.throws(
      () => internals.redirectPlan('http://a.test/x', 'ftp://example.test/secret', 'GET', 'GET'),
      (error) => error instanceof TypeError && /unsupported protocol/.test(error.message),
    );
    for (const route of ['/bad-file', '/bad-ftp']) {
      await assert.rejects(
        fetch(base + route),
        (error) => error instanceof TypeError && /unsupported protocol/.test(error.message),
      );
    }
    pass('non-http(s) redirect targets rejected');

    // 8. HTTPS→HTTP 降级：纯函数规则始终验证。
    assert.throws(
      () => internals.redirectPlan('https://a.test/x', 'http://a.test/y', 'GET', 'GET'),
      (error) => error instanceof TypeError && /HTTPS redirect to HTTP/.test(error.message),
    );
    pass('HTTPS → HTTP downgrade rejected (pure function)');

    // 9. 尽力做端到端降级验证：本机有 openssl 时起自签 HTTPS 服务；没有则说明跳过。
    const tls = createSelfSignedCert();
    if (!tls) {
      console.log('SKIP HTTPS→HTTP downgrade e2e (no openssl; pure-function check above covers the rule)');
    } else {
      const httpsServer = https.createServer(tls, (req, res) => {
        redirectTo(res, 302, targetBase + '/echo');
      });
      const httpsPort = await listen(httpsServer);
      servers.push(httpsServer);
      const hitsBefore = targetHits;
      const previousTls = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
      try {
        await assert.rejects(
          fetch('https://127.0.0.1:' + httpsPort + '/downgrade', {
            headers: { authorization: 'Bearer DOWNGRADE_SECRET' },
          }),
          (error) => error instanceof TypeError && /HTTPS redirect to HTTP/.test(error.message),
        );
        assert.strictEqual(targetHits, hitsBefore, '降级目标的明文服务不应收到任何请求');
        pass('HTTPS → HTTP downgrade rejected end-to-end (self-signed cert)');
      } finally {
        if (previousTls === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
        else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTls;
      }
    }

    console.log('ALL PASS');
  } finally {
    for (const server of servers) await closeServer(server);
  }
})().catch((error) => {
  console.error('FAIL', error);
  process.exitCode = 1;
});
