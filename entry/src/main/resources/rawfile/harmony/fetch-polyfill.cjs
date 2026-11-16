'use strict';
/**
 * fetch 补丁：鸿蒙上 Node 以 --jitless 运行，V8 关闭了 WebAssembly，
 * 而 Node 内置的 undici（fetch）用 WASM 解析 HTTP，于是任何 fetch 都报
 * "WebAssembly is not defined"。这里用 http/https + Web Streams 提供一份
 * 纯 JS 的 fetch，覆盖 DSH 实际用到的语义：JSON、SSE 流式响应、重定向、
 * gzip/br/deflate 解压、AbortSignal。
 *
 * 只在 WebAssembly 不可用时安装；能用 WASM 的环境继续用原生 fetch。
 */
(function install() {
  if (typeof globalThis.WebAssembly !== 'undefined') return;
  if (typeof globalThis.Response !== 'function' || typeof globalThis.ReadableStream !== 'function') {
    console.error('[fetch-polyfill] Response/ReadableStream 不可用，跳过');
    return;
  }

  const http = require('node:http');
  const https = require('node:https');
  const tls = require('node:tls');
  const fs = require('node:fs');
  const path = require('node:path');
  const zlib = require('node:zlib');
  const { Readable } = require('node:stream');

  // 有些开发环境（模拟器、抓包代理）会用本地 CA 做 HTTPS 中间人。它不在
  // Mozilla 根证书里，Node 会报 SELF_SIGNED_CERT_IN_CHAIN。开启这个开关时，
  // 首次遇到证书错误会把这一个中间人根证书抓下来、持久化，并只信任它；
  // 其它主机仍然走正常校验，不会退化成全局关闭校验。
  const trustIntercepted = process.env.DSH_TRUST_INTERCEPTED_CA === '1';
  const caFile = process.env.DSH_INTERCEPTED_CA_FILE || '';
  const userCaCopy = process.env.DSH_INTERCEPTED_CA_COPY || '';
  let extraCa = [];
  if (caFile) {
    try {
      const text = fs.readFileSync(caFile, 'utf8');
      extraCa = text.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) || [];
    } catch (error) { /* 还没有持久化的 CA */ }
  }

  const CERT_ERRORS = [
    'SELF_SIGNED_CERT_IN_CHAIN', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
    'UNABLE_TO_GET_ISSUER_CERT', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY', 'CERT_UNTRUSTED',
    'CERT_SIGNATURE_FAILURE', 'CERT_HAS_EXPIRED', 'CERT_NOT_YET_VALID',
  ];

  function caOption() {
    if (!extraCa.length) return undefined;
    return (tls.rootCertificates || []).concat(extraCa);
  }

  function toPem(raw) {
    const body = raw.toString('base64').replace(/(.{64})/g, '$1\n').replace(/\n$/, '');
    return '-----BEGIN CERTIFICATE-----\n' + body + '\n-----END CERTIFICATE-----\n';
  }

  function lastSelfSigned(cert) {
    let current = cert;
    let last = cert;
    const seen = new Set();
    while (current && current.raw) {
      const id = current.fingerprint || current.serialNumber;
      if (id && seen.has(id)) break;
      if (id) seen.add(id);
      last = current;
      const issuer = current.issuerCertificate;
      if (!issuer || issuer === current || !issuer.raw) break;
      current = issuer;
    }
    return last;
  }

  function captureInterceptedCa(host, port, servername) {
    return new Promise((resolve, reject) => {
      const socket = tls.connect({ host, port, servername, rejectUnauthorized: false }, () => {
        try {
          const root = lastSelfSigned(socket.getPeerCertificate(true));
          socket.end();
          if (!root || !root.raw) return reject(new Error('no peer certificate'));
          resolve(toPem(root.raw));
        } catch (error) {
          socket.destroy();
          reject(error);
        }
      });
      socket.on('error', reject);
    });
  }

  function rememberCa(pem) {
    if (extraCa.indexOf(pem) >= 0) return;
    extraCa.push(pem);
    if (caFile) {
      try {
        fs.mkdirSync(path.dirname(caFile), { recursive: true });
        fs.appendFileSync(caFile, pem);
      } catch (error) { /* 持久化失败只影响下次启动 */ }
    }
    if (userCaCopy) {
      try { fs.writeFileSync(userCaCopy, pem); } catch (error) { /* 供用户手动安装 */ }
    }
    console.error('[fetch-polyfill] 已信任被拦截的中间人 CA，并保存到', caFile);
  }

  const MAX_REDIRECTS = 20;
  const agents = {
    'http:': new http.Agent({ keepAlive: true }),
    'https:': new https.Agent({ keepAlive: true }),
  };

  function headerObject(input) {
    const out = {};
    if (!input) return out;
    if (typeof input.forEach === 'function' && typeof input.get === 'function') {
      input.forEach((value, key) => { out[key] = value; });
      return out;
    }
    if (Array.isArray(input)) {
      for (const pair of input) {
        if (pair && pair.length >= 2) out[String(pair[0])] = String(pair[1]);
      }
      return out;
    }
    for (const key of Object.keys(input)) {
      const value = input[key];
      if (value === undefined || value === null) continue;
      out[key] = Array.isArray(value) ? value.join(', ') : String(value);
    }
    return out;
  }

  function bodyBuffer(body) {
    if (body === undefined || body === null) return null;
    if (Buffer.isBuffer(body)) return body;
    if (typeof body === 'string') return Buffer.from(body, 'utf8');
    if (body instanceof Uint8Array) return Buffer.from(body.buffer, body.byteOffset, body.byteLength);
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      return Buffer.from(body.toString(), 'utf8');
    }
    if (typeof body === 'object' && typeof body.toString === 'function') {
      return Buffer.from(String(body), 'utf8');
    }
    return null;
  }

  function decode(stream, encoding, headers) {
    const value = String(headers['content-encoding'] || '').toLowerCase();
    let decoder = null;
    if (encoding === 'gzip' && value === 'gzip') decoder = zlib.createGunzip();
    else if (encoding === 'br' && value === 'br') decoder = zlib.createBrotliDecompress();
    else if (encoding === 'deflate' && (value === 'deflate' || value === 'deflate-raw')) {
      decoder = zlib.createInflate();
    }
    if (!decoder) return stream;
    delete headers['content-encoding'];
    delete headers['content-length'];
    return stream.pipe(decoder);
  }

  function toWeb(response, method) {
    const headers = headerObject(response.headers);
    // 让上游看到解压后的内容，同时保持流式（SSE 不能被整块缓冲）。
    const stream = decode(response, method, headers);
    const body = Readable.toWeb(stream);
    const status = response.statusCode || 502;
    return new Response(body, { status, statusText: response.statusMessage || '', headers });
  }

  function requestOnce(url, init, redirects, retried) {
    return new Promise((resolve, reject) => {
      const parsed = new URL(url);
      const transport = parsed.protocol === 'http:' ? http : https;
      const headers = headerObject(init.headers);
      const body = bodyBuffer(init.body);
      const method = String(init.method || 'GET').toUpperCase();

      if (body && !headers['content-length'] && !headers['Content-Length']) {
        headers['content-length'] = String(body.length);
      }
      // 没有显式要求压缩时不主动加 accept-encoding，避免多一层解压逻辑。
      if (!headers['accept-encoding'] && !headers['Accept-Encoding']) {
        headers['accept-encoding'] = 'gzip, deflate, br';
      }

      const options = {
        method,
        headers,
        agent: agents[parsed.protocol],
      };
      // 已信任的中间人 CA 只叠加在 Mozilla 根证书之上，替换默认列表时会显式合并。
      if (transport === https && extraCa.length) options.ca = caOption();

      const req = transport.request(parsed, options, (response) => {
        const status = response.statusCode || 0;
        const location = response.headers.location;
        if (location && [301, 302, 303, 307, 308].indexOf(status) >= 0 && redirects > 0) {
          response.resume();
          let nextMethod = method;
          let nextBody = init.body;
          if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
            nextMethod = 'GET';
            nextBody = undefined;
          }
          const next = new URL(location, parsed).toString();
          return resolve(requestOnce(next, Object.assign({}, init, {
            method: nextMethod,
            body: nextBody,
          }), redirects - 1));
        }
        resolve(toWeb(response, method));
      });

      req.on('error', (error) => {
        // 证书链错误且允许信任中间人 CA：抓一次根证书、持久化，然后用它重试。
        // 只信任抓到的这一张，其它主机和之后的请求仍然做完整校验。
        if (trustIntercepted && !retried && CERT_ERRORS.indexOf(error.code) >= 0) {
          const port = parsed.port ? Number(parsed.port) : 443;
          captureInterceptedCa(parsed.hostname, port, parsed.hostname)
            .then((pem) => {
              rememberCa(pem);
              resolve(requestOnce(url, init, redirects, true));
            })
            .catch(() => {
              console.error('[fetch-polyfill] failed', parsed.host, parsed.pathname, error.code || '', error.message);
              reject(new TypeError('fetch failed: ' + error.message, { cause: error }));
            });
          return;
        }
        console.error('[fetch-polyfill] failed', parsed.host, parsed.pathname, error.code || '', error.message);
        reject(new TypeError('fetch failed: ' + error.message, { cause: error }));
      });

      const signal = init.signal;
      if (signal) {
        if (signal.aborted) {
          req.destroy();
          reject(signal.reason instanceof Error ? signal.reason : new Error('The operation was aborted'));
          return;
        }
        const onAbort = () => {
          req.destroy();
          reject(signal.reason instanceof Error ? signal.reason : new Error('The operation was aborted'));
        };
        signal.addEventListener('abort', onAbort, { once: true });
        req.on('close', () => signal.removeEventListener('abort', onAbort));
      }

      if (body) req.write(body);
      req.end();
    });
  }

  // 有些调用方传 Request 对象：取它的 url / method / headers / body。
  function normalizeInput(input, init) {
    if (input && typeof input === 'object' && typeof input.url === 'string') {
      const merged = Object.assign({}, init);
      if (merged.method === undefined) merged.method = input.method;
      if (merged.headers === undefined) merged.headers = input.headers;
      if (merged.body === undefined && input.body !== undefined) merged.body = input.body;
      return { url: input.url, init: merged };
    }
    return { url: String(input), init: init || {} };
  }

  const nativeRequest = globalThis.fetch;
  globalThis.fetch = function fetch(input, init) {
    try {
      const normalized = normalizeInput(input, init);
      return requestOnce(normalized.url, normalized.init, MAX_REDIRECTS);
    } catch (error) {
      return Promise.reject(error);
    }
  };
  globalThis.fetch.__harmonyPolyfill = true;
})();
