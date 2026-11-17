// 回归测试：Index.ets 里的 RESOURCE_URL_DOCUMENT_SCRIPT。
//
// ArkWeb 把 dsh-resource:// 当 opaque URL 解析，hostname 恒为空；上游
// dsh-client-resources 的 protocolOf() 用 hostname 当协议键，于是文件预览
// 显示「文件资源服务不可用」。这个测试从 Index.ets 原样取出注入脚本，在
// 模拟「hostname 恒空」的 URL 实现上验证兜底，并确认正常内核不受影响。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const INDEX = path.join(__dirname, '..', 'entry/src/main/ets/pages/Index.ets');

function loadShim() {
  const source = fs.readFileSync(INDEX, 'utf8');
  const match = source.match(
    /const RESOURCE_URL_DOCUMENT_SCRIPT: string =([\s\S]*?);\r?\n\/\/ __RESOURCE_URL_SHIM_END__/,
  );
  assert.ok(match, 'Index.ets 里找不到 RESOURCE_URL_DOCUMENT_SCRIPT 常量');
  return Function('return (' + match[1] + ');')();
}

function authorityHost(href) {
  const match = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(href);
  if (match === null) return '';
  let authority = match[1];
  const at = authority.lastIndexOf('@');
  if (at >= 0) authority = authority.slice(at + 1);
  const colon = authority.lastIndexOf(':');
  if (colon >= 0) authority = authority.slice(0, colon);
  return authority.toLowerCase();
}

/** ArkWeb 形态：非特殊 scheme 的 authority 不会进 hostname。 */
class OpaqueHostURL {
  constructor(input) {
    this.href = String(input);
    const colon = this.href.indexOf(':');
    this.protocol = colon < 0 ? '' : this.href.slice(0, colon + 1).toLowerCase();
  }

  get hostname() {
    // 非特殊 scheme 在 ArkWeb 上都没有 host，不只是 dsh-resource。
    if (!/^(https?|wss?|ftp|file):$/.test(this.protocol)) return '';
    return authorityHost(this.href);
  }
}

/** 解析正常的引擎：dsh-resource 的 hostname 本来就是 file。 */
class ModernURL extends OpaqueHostURL {
  get hostname() {
    return authorityHost(this.href);
  }
}

function withURL(FakeURL, run) {
  const hadWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window');
  const previousWindow = globalThis.window;
  const previousURL = globalThis.URL;
  const previousShim = globalThis.__dshResourceUrlShim;
  globalThis.window = globalThis;
  globalThis.URL = FakeURL;
  delete globalThis.__dshResourceUrlShim;
  try {
    run();
  } finally {
    globalThis.URL = previousURL;
    if (hadWindow) globalThis.window = previousWindow;
    else delete globalThis.window;
    if (previousShim === undefined) delete globalThis.__dshResourceUrlShim;
    else globalThis.__dshResourceUrlShim = previousShim;
  }
}

const shim = loadShim();

test('shim 在文档起点、早于上传与桥脚本注入', () => {
  const source = fs.readFileSync(INDEX, 'utf8');
  const block = /\.javaScriptOnDocumentStart\(\[([\s\S]*?)\]\)/.exec(source);
  assert.ok(block, 'Index.ets 里找不到 javaScriptOnDocumentStart');
  const order = [...block[1].matchAll(/script:\s*([A-Z_]+)/g)].map((m) => m[1]);
  assert.deepEqual(order, [
    'RESOURCE_URL_DOCUMENT_SCRIPT',
    'UPLOAD_DOCUMENT_SCRIPT',
    'BRIDGE_DOCUMENT_SCRIPT',
  ]);
});

test('ArkWeb 上从 dsh-resource 地址补出 host', () => {
  withURL(OpaqueHostURL, () => {
    // 前置条件：这正是触发线上问题的内核行为。
    assert.equal(new URL('dsh-resource://file/session/s1/a.md').hostname, '');
    (0, eval)(shim); // eslint-disable-line no-eval
    assert.equal(new URL('dsh-resource://file/session/s1/a.md').hostname, 'file');
    assert.equal(new URL('DSH-RESOURCE://File/session/s1/a.md').hostname, 'file');
    assert.equal(new URL('dsh-resource://user@file:8080/x').hostname, 'file');
  });
});

test('没有 host 的地址仍然没有 host', () => {
  withURL(OpaqueHostURL, () => {
    (0, eval)(shim); // eslint-disable-line no-eval
    assert.equal(new URL('dsh-resource:///no-host').hostname, '');
    assert.equal(new URL('dsh-resource:no-slash').hostname, '');
    assert.equal(new URL('dsh-resource://bad host/x').hostname, '');
  });
});

test('其它 scheme 保持原样', () => {
  withURL(OpaqueHostURL, () => {
    (0, eval)(shim); // eslint-disable-line no-eval
    assert.equal(new URL('https://example.com/a').hostname, 'example.com');
    assert.equal(new URL('http://127.0.0.1:3080/').hostname, '127.0.0.1');
    assert.equal(new URL('sidebar://guide').hostname, '');
  });
});

test('解析正常的引擎不被改写', () => {
  withURL(ModernURL, () => {
    (0, eval)(shim); // eslint-disable-line no-eval
    assert.equal(new URL('dsh-resource://file/session/s1/a.md').hostname, 'file');
  });
});

test('重复注入是幂等的', () => {
  withURL(OpaqueHostURL, () => {
    (0, eval)(shim); // eslint-disable-line no-eval
    (0, eval)(shim); // eslint-disable-line no-eval
    assert.equal(new URL('dsh-resource://file/session/s1/a.md').hostname, 'file');
  });
});
