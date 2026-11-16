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
  const zlib = require('node:zlib');
  const { Readable } = require('node:stream');

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

  function requestOnce(url, init, redirects) {
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

      const req = transport.request(parsed, {
        method,
        headers,
        agent: agents[parsed.protocol],
      }, (response) => {
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
