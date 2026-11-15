// 鸿蒙无 JIT 环境下，Node 内置 fetch 的 llhttp WASM 解析器不可用。
// 使用 node-fetch 的原生 HTTP 实现，并保留标准 Web Request/Response/Stream 边界。
import nodeFetch from 'node-fetch';
import { Readable } from 'node:stream';

const WebRequest = globalThis.Request;
const WebResponse = globalThis.Response;
const WebHeaders = globalThis.Headers;
globalThis.fetch = async function harmonyFetch(input, init) {
  const request = new WebRequest(input, init);
  const body = request.body === null ? undefined : Readable.fromWeb(request.body);
  const response = await nodeFetch(request.url, {
    method: request.method,
    headers: Object.fromEntries(request.headers),
    body,
    signal: request.signal,
    redirect: request.redirect,
    // 不设置无限重试；保留上游引擎自己的重试策略。
  });
  const headers = new WebHeaders();
  for (const [name, values] of Object.entries(response.headers.raw())) {
    for (const value of values) headers.append(name, value);
  }
  const responseBody = request.method === 'HEAD' || [101, 204, 205, 304].includes(response.status)
    ? null : Readable.toWeb(response.body);
  const result = new WebResponse(responseBody, { status: response.status, statusText: response.statusText, headers });
  Object.defineProperties(result, {
    url: { value: response.url }, redirected: { value: response.redirected }, type: { value: 'basic' },
  });
  return result;
};
