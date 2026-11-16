'use strict';
/**
 * fetch 补丁：鸿蒙上 Node 以 --jitless 运行，V8 不暴露 WebAssembly，
 * 而 Node 内置的 undici（fetch）用 WASM 解析 HTTP，直接调用会报
 * "WebAssembly is not defined"。
 *
 * 这里用 http/https + Web Streams 实现一份纯 JS 的 fetch，尽量对齐 WHATWG
 * fetch 在 DSH 里用到的语义：
 *   - 请求体：string / Buffer / Uint8Array / ArrayBuffer / URLSearchParams /
 *     Blob / FormData（multipart）/ ReadableStream / Node Readable
 *   - 响应：流式 body（SSE 不被整块缓冲）、gzip/br/deflate 解压
 *   - 重定向：follow / error / manual，方法改写符合规范
 *   - AbortSignal：中止时以 AbortError 拒绝
 *   - HEAD/204/304 的 body 为 null
 *   - 响应对象带 url / type / redirected
 *
 * 只在 WebAssembly 不可用时安装；DSH_FORCE_FETCH_POLYFILL=1 可强制安装用于测试。
 */
(function install() {
  const force = process.env.DSH_FORCE_FETCH_POLYFILL === '1';
  if (!force && typeof globalThis.WebAssembly !== 'undefined') return;
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

  function abortError(signal) {
    const reason = signal && signal.reason;
    if (reason instanceof Error) return reason;
    if (typeof DOMException === 'function') {
      return new DOMException('This operation was aborted', 'AbortError');
    }
    const error = new Error('This operation was aborted');
    error.name = 'AbortError';
    return error;
  }

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

  function hasHeader(headers, name) {
    const lower = name.toLowerCase();
    return Object.keys(headers).some((key) => key.toLowerCase() === lower);
  }

  function setHeader(headers, name, value) {
    if (!hasHeader(headers, name)) headers[name] = value;
  }

  function isNodeReadable(value) {
    return value && typeof value.pipe === 'function' && typeof value.on === 'function';
  }

  function isWebReadable(value) {
    return value && typeof value.getReader === 'function';
  }

  function escapeName(value) {
    return String(value).replace(/["\r\n]/g, '_');
  }

  async function encodeFormDataAsync(formData) {
    const boundary = '----DSHFormBoundary' + Math.random().toString(16).slice(2) + Date.now().toString(16);
    const chunks = [];
    for (const entry of formData.entries()) {
      const name = escapeName(entry[0]);
      const value = entry[1];
      chunks.push(Buffer.from('--' + boundary + '\r\n'));
      if (typeof value === 'string') {
        chunks.push(Buffer.from('Content-Disposition: form-data; name="' + name + '"\r\n\r\n' + value + '\r\n', 'utf8'));
      } else {
        const filename = escapeName(value.name || 'blob');
        const type = value.type || 'application/octet-stream';
        chunks.push(Buffer.from(
          'Content-Disposition: form-data; name="' + name + '"; filename="' + filename + '"\r\n' +
          'Content-Type: ' + type + '\r\n\r\n', 'utf8'));
        if (typeof value.arrayBuffer === 'function') {
          chunks.push(Buffer.from(await value.arrayBuffer()));
        } else if (typeof value.text === 'function') {
          chunks.push(Buffer.from(await value.text(), 'utf8'));
        }
        chunks.push(Buffer.from('\r\n'));
      }
    }
    chunks.push(Buffer.from('--' + boundary + '--\r\n'));
    return { buffer: Buffer.concat(chunks), boundary };
  }

  // 返回 { buffer } 或 { stream }；同时按规范补默认 content-type。
  async function prepareBody(body, headers, method) {
    if (body === undefined || body === null) return { buffer: null };
    if (method === 'GET' || method === 'HEAD') return { buffer: null };

    if (typeof body === 'string') {
      setHeader(headers, 'content-type', 'text/plain;charset=UTF-8');
      return { buffer: Buffer.from(body, 'utf8') };
    }
    if (Buffer.isBuffer(body)) return { buffer: body };
    if (body instanceof Uint8Array) return { buffer: Buffer.from(body.buffer, body.byteOffset, body.byteLength) };
    if (body instanceof ArrayBuffer) return { buffer: Buffer.from(body) };
    if (ArrayBuffer.isView(body)) return { buffer: Buffer.from(body.buffer, body.byteOffset, body.byteLength) };

    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      setHeader(headers, 'content-type', 'application/x-www-form-urlencoded;charset=UTF-8');
      return { buffer: Buffer.from(body.toString(), 'utf8') };
    }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      const encoded = await encodeFormDataAsync(body);
      headers['content-type'] = 'multipart/form-data; boundary=' + encoded.boundary;
      return { buffer: encoded.buffer };
    }
    if (typeof Blob !== 'undefined' && body instanceof Blob) {
      if (body.type) setHeader(headers, 'content-type', body.type);
      return { buffer: Buffer.from(await body.arrayBuffer()) };
    }
    if (isWebReadable(body)) {
      return { stream: Readable.fromWeb(body) };
    }
    if (isNodeReadable(body)) {
      return { stream: body };
    }
    if (typeof body === 'object' && typeof body.toString === 'function') {
      return { buffer: Buffer.from(String(body), 'utf8') };
    }
    return { buffer: null };
  }

  function decode(stream, headers) {
    const value = String(headers['content-encoding'] || '').toLowerCase();
    let decoder = null;
    if (value === 'gzip' || value === 'x-gzip') decoder = zlib.createGunzip();
    else if (value === 'br') decoder = zlib.createBrotliDecompress();
    else if (value === 'deflate' || value === 'deflate-raw') decoder = zlib.createInflate();
    if (!decoder) return stream;
    delete headers['content-encoding'];
    delete headers['content-length'];
    return stream.pipe(decoder);
  }

  function makeResponse(response, method, url, redirected) {
    const headers = headerObject(response.headers);
    const status = response.statusCode || 502;
    const nullBody = method === 'HEAD' || status === 204 || status === 304;
    const stream = nullBody ? null : decode(response, headers);
    const body = stream ? Readable.toWeb(stream) : null;
    const result = new Response(body, {
      status,
      statusText: response.statusMessage || '',
      headers,
    });
    Object.defineProperty(result, 'url', { value: url, enumerable: true });
    Object.defineProperty(result, 'redirected', { value: redirected, enumerable: true });
    Object.defineProperty(result, 'type', { value: 'basic', enumerable: true });
    return result;
  }

  function requestOnce(url, init, redirects, redirected) {
    return new Promise((resolve, reject) => {
      const parsed = new URL(url);
      const transport = parsed.protocol === 'http:' ? http : https;
      const method = String(init.method || 'GET').toUpperCase();
      const headers = headerObject(init.headers);
      const signal = init.signal;

      if (signal && signal.aborted) {
        reject(abortError(signal));
        return;
      }

      prepareBody(init.body, headers, method).then((prepared) => {
        if (signal && signal.aborted) {
          reject(abortError(signal));
          return;
        }
        const options = {
          method,
          headers,
          agent: agents[parsed.protocol],
        };
        if (prepared.buffer) {
          headers['content-length'] = String(prepared.buffer.length);
        }
        if (!hasHeader(headers, 'accept-encoding')) {
          headers['accept-encoding'] = 'gzip, deflate, br';
        }

        const req = transport.request(parsed, options, (response) => {
          const status = response.statusCode || 0;
          const location = response.headers.location;
          const mode = init.redirect || 'follow';

          if (location && [301, 302, 303, 307, 308].indexOf(status) >= 0) {
            if (mode === 'error') {
              response.resume();
              reject(new TypeError('fetch failed: redirect mode is error'));
              return;
            }
            if (mode === 'follow' && redirects > 0) {
              response.resume();
              let nextMethod = method;
              let nextBody = init.body;
              if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
                nextMethod = 'GET';
                nextBody = undefined;
              }
              const next = new URL(location, parsed).toString();
              requestOnce(next, Object.assign({}, init, {
                method: nextMethod,
                body: nextBody,
              }), redirects - 1, true).then(resolve, reject);
              return;
            }
            // manual：返回 3xx 本身，不自动跟随。
            resolve(makeResponse(response, method, url, redirected));
            return;
          }
          resolve(makeResponse(response, method, url, redirected));
        });

        req.on('error', (error) => {
          if (signal && signal.aborted) {
            reject(abortError(signal));
            return;
          }
          console.error('[fetch-polyfill] failed', parsed.host, parsed.pathname, error.code || '', error.message);
          reject(new TypeError('fetch failed: ' + error.message, { cause: error }));
        });

        if (signal) {
          const onAbort = () => {
            req.destroy();
            reject(abortError(signal));
          };
          signal.addEventListener('abort', onAbort, { once: true });
          req.on('close', () => signal.removeEventListener('abort', onAbort));
        }

        if (prepared.buffer) {
          req.end(prepared.buffer);
        } else if (prepared.stream) {
          prepared.stream.on('error', (error) => {
            req.destroy();
            reject(new TypeError('fetch failed: ' + error.message, { cause: error }));
          });
          prepared.stream.pipe(req);
        } else {
          req.end();
        }
      }, (error) => reject(new TypeError('fetch failed: ' + error.message, { cause: error })));
    });
  }

  function normalizeInput(input, init) {
    if (input && typeof input === 'object' && typeof input.url === 'string') {
      const merged = Object.assign({}, init);
      if (merged.method === undefined) merged.method = input.method;
      if (merged.headers === undefined) merged.headers = input.headers;
      if (merged.body === undefined && input.body !== undefined) merged.body = input.body;
      if (merged.signal === undefined) merged.signal = input.signal;
      if (merged.redirect === undefined) merged.redirect = input.redirect;
      return { url: input.url, init: merged };
    }
    return { url: String(input), init: init || {} };
  }

  globalThis.fetch = function fetch(input, init) {
    try {
      const normalized = normalizeInput(input, init);
      return requestOnce(normalized.url, normalized.init, MAX_REDIRECTS, false);
    } catch (error) {
      return Promise.reject(error);
    }
  };
  globalThis.fetch.__harmonyPolyfill = true;
})();
