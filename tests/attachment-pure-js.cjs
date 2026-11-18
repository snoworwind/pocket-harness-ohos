const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');

const root = path.join(__dirname, '..');
const engineArchive = path.join(root, 'entry/src/main/resources/rawfile/tools/official-engine.tar.gz');
// 引擎归档是构建产物（.gitignore），clean checkout / CI 里不存在；依赖它的用例
// 跳过而不是让整个宿主测试失败。本地打包后仍会完整执行。
const engineArchiveSkip = fs.existsSync(engineArchive)
  ? false
  : '缺少 entry/src/main/resources/rawfile/tools/official-engine.tar.gz（构建产物，clean checkout 不提供）';
const attachmentSourcePath = './node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js';

// ── 上传钩子：直接从 Index.ets 取出实际注入的脚本，避免测试与实现漂移 ────────────
function uploadDocumentScript() {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  const start = source.indexOf('const UPLOAD_DOCUMENT_SCRIPT');
  assert.ok(start >= 0, 'Index.ets must declare UPLOAD_DOCUMENT_SCRIPT');
  // 声明由若干个双引号字符串用 + 连接；分号可能出现在字符串内部，不能直接找 ';'。
  let index = source.indexOf('=', start) + 1;
  let quote = false;
  for (; index < source.length; index += 1) {
    const character = source[index];
    if (quote && character === '\\') index += 1;
    else if (character === '"') quote = !quote;
    else if (!quote && character === ';') break;
  }
  assert.ok(!quote && index < source.length, 'UPLOAD_DOCUMENT_SCRIPT declaration must end with a semicolon');
  const declaration = source.slice(start, index);
  const parts = [...declaration.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((match) => JSON.parse(`"${match[1]}"`));
  assert.ok(parts.length > 0, 'UPLOAD_DOCUMENT_SCRIPT must be a concatenated string literal');
  return parts.join('');
}

function installUploadHook(fetchImpl) {
  const window = {};
  vm.runInNewContext(uploadDocumentScript(), { window, fetch: fetchImpl, Blob, Promise, ArrayBuffer }, { filename: 'upload-document-script.js' });
  assert.equal(typeof window.__DSH_FILE_UPLOAD__, 'object');
  assert.equal(typeof window.__DSH_FILE_UPLOAD__.fetch, 'function');
  return window.__DSH_FILE_UPLOAD__.fetch;
}

test('upload hook is installed at document start and exposes fetch', () => {
  installUploadHook(async () => new Response('ok', { status: 200 }));
});

test('upload hook forwards non-Blob bodies untouched', async () => {
  const calls = [];
  const post = installUploadHook(async (input, init) => {
    calls.push([input, init]);
    return new Response('ok', { status: 200 });
  });
  const body = new Uint8Array([1, 2, 3]);
  await post('api/session/uploadFileBinary', { method: 'POST', body });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1].body, body);
});

test('upload hook posts Blob bodies directly when the kernel accepts them', async () => {
  const calls = [];
  const post = installUploadHook(async (input, init) => {
    calls.push([input, init]);
    return new Response('ok', { status: 200 });
  });
  const body = new Blob([new Uint8Array([4, 5, 6])], { type: 'application/octet-stream' });
  const headers = { 'content-type': 'application/octet-stream' };
  const response = await post('api/session/uploadFileBinary?sessionId=s', { method: 'POST', headers, body });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1].body, body);
  assert.equal(calls[0][1].headers, headers);
});

test('upload hook retries a rejected Blob body as ArrayBuffer, preserving request options', async () => {
  const calls = [];
  const post = installUploadHook(async (input, init) => {
    calls.push([input, init]);
    if (calls.length === 1) throw new Error('blob body rejected by ArkWeb');
    return new Response('stored', { status: 200 });
  });
  const body = new Blob([new Uint8Array([7, 8, 9])], { type: 'application/octet-stream' });
  const headers = { 'content-type': 'application/octet-stream' };
  const response = await post('api/session/uploadFileBinary?sessionId=s', { method: 'POST', headers, body, duplex: 'half' });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  assert.equal(calls[1][1].method, 'POST');
  assert.equal(calls[1][1].headers, headers);
  assert.equal('duplex' in calls[1][1], false);
  assert.deepEqual([...new Uint8Array(calls[1][1].body)], [7, 8, 9]);
});

test('upload hook does not retry after abort, and surfaces the retry failure', async () => {
  const post = installUploadHook(async () => { throw new Error('still rejected'); });
  const body = new Blob([new Uint8Array([1])]);
  await assert.rejects(post('api/session/uploadFileBinary', { method: 'POST', body }), /still rejected/);

  const controller = new AbortController();
  controller.abort();
  const calls = [];
  const aborted = installUploadHook(async (input, init) => {
    calls.push(init);
    throw new Error('aborted request');
  });
  await assert.rejects(aborted('api/session/uploadFileBinary', { method: 'POST', body, signal: controller.signal }), /aborted request/);
  assert.equal(calls.length, 1);
});

// ── 引擎补丁：从实际归档里取出 attachment-local，打补丁后按模块语义执行 ────────
function readTarFile(archive, wantedSuffix) {
  const raw = zlib.gunzipSync(fs.readFileSync(archive));
  let offset = 0;
  while (offset + 512 <= raw.length) {
    const header = raw.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/su, '');
    const size = Number.parseInt(header.subarray(124, 136).toString('utf8').replace(/\0.*$/su, '').trim() || '0', 8);
    if (name === wantedSuffix || name.endsWith(wantedSuffix)) {
      return raw.subarray(offset + 512, offset + 512 + size);
    }
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  return null;
}

async function loadPatchedAttachmentModule() {
  if (!fs.existsSync(engineArchive)) return null;
  const { applyAttachmentPatch } = await import('../scripts/engine-patch/attachment-pure-js.mjs');
  const extracted = readTarFile(engineArchive, attachmentSourcePath);
  if (extracted === null) return null;
  let source = extracted.toString('utf8');
  // 先补丁（要求原文件仍有 export 块），再在测试桩里去掉 import/export。
  // 归档可能已经打过补丁（pack-native 重新打包后）：applyAttachmentPatch 会返回 changed=false。
  source = applyAttachmentPatch(source).source
    .replace(/^import[^\n]*\n/gm, '')
    .replace(/^export \{[\s\S]*?\};\s*$/m, '')
    .replace(/import\.meta\.url/g, '"file:///attachment-local/lib/index.js"');
  const factory = new Function('require', `
    const { dirname, join, parse, resolve } = require('node:path');
    const { createHash, randomUUID } = require('node:crypto');
    const { constants, createReadStream } = require('node:fs');
    const { chmod, link, mkdir, open, readFile, rename, rm, unlink, writeFile } = require('node:fs/promises');
    const chain = new Proxy(function () {}, { get: () => chain, apply: () => chain });
    const z = chain;
    class AttachmentError extends Error {
      constructor(message, code, options) {
        super(message);
        this.name = 'AttachmentError';
        this.code = code;
        if (options && options.cause) this.cause = options.cause;
      }
    }
    class AttachmentStore { constructor(ctx) { this.ctx = ctx; } }
    const AttachmentId = (value) => value;
    const ImageVariantId = (value) => value;
    const requestImageDimensions = (width, height) => ({ width, height });
    const resolveDshHome = (home) => home;
    const dshCachePath = (options, suffix) => options.dshHome + '/' + suffix;
    const createLazyRequire = () => () => { throw new Error('sharp is not available in this engine'); };
    ${source}
    return { prepareImageFile, normalizeImage, validateImageFile, readRequestImageFile, readImageFile, LocalAttachmentStore };
  `);
  return { api: factory(require), applyAttachmentPatch, source };
}

const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64'
);

function makeJpeg(width, height, { app1 = false } = {}) {
  const chunks = [Buffer.from([0xff, 0xd8])];
  if (app1) {
    const payload = Buffer.from('Exif\0\0MM\0*', 'binary');
    const segment = Buffer.alloc(4 + payload.length);
    segment[0] = 0xff; segment[1] = 0xe1;
    segment.writeUInt16BE(2 + payload.length, 2);
    payload.copy(segment, 4);
    chunks.push(segment);
  }
  const sof = Buffer.from([
    0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01
  ]);
  chunks.push(sof);
  chunks.push(Buffer.from([0xff, 0xd9]));
  return Buffer.concat(chunks);
}

function makeWebp(width, height, flags = 0) {
  const chunk = Buffer.alloc(18);
  chunk.write('VP8X', 0, 'ascii');
  chunk.writeUInt32LE(10, 4);
  chunk[8] = flags;
  chunk.writeUIntLE(width - 1, 12, 3);
  chunk.writeUIntLE(height - 1, 15, 3);
  const body = Buffer.concat([Buffer.from('WEBP'), chunk]);
  const riff = Buffer.alloc(8);
  riff.write('RIFF', 0, 'ascii');
  riff.writeUInt32LE(body.length, 4);
  return Buffer.concat([riff, body]);
}

function makeGif(width, height) {
  const gif = Buffer.alloc(13);
  gif.write('GIF89a', 0, 'ascii');
  gif.writeUInt16LE(width, 6);
  gif.writeUInt16LE(height, 8);
  gif[10] = 0;
  return gif;
}

const LIMITS = { maxImageBytes: 50 * 1024 * 1024, maxImagePixels: 64_000_000, maxImageDimension: 65_535 };
const POLICY = { maxPixels: 4 * 1024 * 1024, maxDimension: 8192, maxBytes: 4 * 1024 * 1024 };

let loadedPromise;
function load() {
  loadedPromise ??= loadPatchedAttachmentModule();
  return loadedPromise;
}

test('attachment patch is idempotent and rejects an unknown module layout', async (t) => {
  const loaded = await load();
  if (loaded === null) return t.skip(engineArchiveSkip);
  const once = loaded.applyAttachmentPatch(loaded.source);
  assert.equal(once.changed, false);
  assert.throws(() => loaded.applyAttachmentPatch('export { };\n'), /not found/);
});

test('image admission parses PNG/JPEG/WebP/GIF headers without sharp', async (t) => {
  const loaded = await load();
  if (loaded === null) return t.skip(engineArchiveSkip);
  const { prepareImageFile } = loaded.api;
  const cases = [
    ['image/png', PNG_1X1, 1, 1],
    ['image/jpeg', makeJpeg(3, 2, { app1: true }), 3, 2],
    ['image/webp', makeWebp(7, 5, 0x12), 7, 5],
    ['image/gif', makeGif(9, 4), 9, 4]
  ];
  for (const [mediaType, bytes, width, height] of cases) {
    const data = new Uint8Array(bytes);
    const prepared = await prepareImageFile({ data, mediaType, name: `a.${mediaType.slice(6)}` }, LIMITS, POLICY);
    assert.equal(prepared.ref.mediaType, mediaType);
    assert.equal(prepared.ref.width, width);
    assert.equal(prepared.ref.height, height);
    assert.equal(prepared.ref.bytes, data.byteLength);
    // 无编码器：原字节透传，不做重编码/降采样。
    assert.equal(prepared.data, data);
    assert.equal(prepared.ref.originalDimensions, undefined);
  }
});

test('image admission still rejects malformed and mismatched images', async (t) => {
  const loaded = await load();
  if (loaded === null) return t.skip(engineArchiveSkip);
  const { prepareImageFile } = loaded.api;
  await assert.rejects(
    prepareImageFile({ data: new Uint8Array(32), mediaType: 'image/png' }, LIMITS, POLICY),
    (error) => error.code === 'INVALID_IMAGE'
  );
  await assert.rejects(
    prepareImageFile({ data: new Uint8Array(PNG_1X1), mediaType: 'image/jpeg' }, LIMITS, POLICY),
    (error) => error.code === 'IMAGE_TYPE_MISMATCH'
  );
  await assert.rejects(
    prepareImageFile({ data: new Uint8Array(PNG_1X1), mediaType: 'image/png' }, { ...LIMITS, maxImagePixels: 0 }, POLICY),
    (error) => error.code === 'IMAGE_TOO_MANY_PIXELS'
  );
});

test('request projection passes stored image bytes through unchanged', async (t) => {
  const loaded = await load();
  if (loaded === null) return t.skip(engineArchiveSkip);
  const { prepareImageFile, readRequestImageFile } = loaded.api;
  const data = new Uint8Array(makeJpeg(2600, 1800, { app1: true }));
  const prepared = await prepareImageFile({ data, mediaType: 'image/jpeg' }, LIMITS, POLICY);
  const cacheRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ph-attachment-cache-'));
  try {
    const request = await readRequestImageFile(cacheRoot, prepared, { width: 1024, height: 1024, maxBytes: 1024 * 1024 });
    assert.equal(request.data, data);
    assert.equal(request.width, 2600);
    assert.equal(request.height, 1800);
    assert.equal(request.mediaType, 'image/jpeg');
    assert.equal(request.attachment, prepared.ref);
  } finally {
    fs.rmSync(cacheRoot, { recursive: true, force: true });
  }
});

test('stored images can be read back and verified with header facts', async (t) => {
  const loaded = await load();
  if (loaded === null) return t.skip(engineArchiveSkip);
  const { prepareImageFile, readImageFile } = loaded.api;
  const data = new Uint8Array(makeJpeg(12, 8));
  const prepared = await prepareImageFile({ data, mediaType: 'image/jpeg' }, LIMITS, POLICY);
  const attachmentRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ph-attachment-root-'));
  const sha = prepared.ref.attachmentId.slice('sha256:'.length);
  const objectPath = path.join(attachmentRoot, 'objects', sha.slice(0, 2), sha);
  fs.mkdirSync(path.dirname(objectPath), { recursive: true });
  fs.writeFileSync(objectPath, data);
  try {
    const read = await readImageFile(attachmentRoot, prepared.ref);
    assert.equal(read.data.byteLength, data.byteLength);
    assert.equal(read.ref.attachmentId, prepared.ref.attachmentId);
  } finally {
    fs.rmSync(attachmentRoot, { recursive: true, force: true });
  }
});

test('durability walk stops at an inaccessible sandbox boundary', async (t) => {
  const loaded = await load();
  if (loaded === null) return t.skip(engineArchiveSkip);
  if (process.platform === 'win32') return t.skip('POSIX permission semantics required');
  const { LocalAttachmentStore } = loaded.api;
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'ph-attachment-boundary-'));
  const blocked = path.join(base, 'blocked');
  const home = path.join(blocked, 'home');
  fs.mkdirSync(home, { recursive: true });
  // 可执行但不可读：能 stat 到后代，但 open(O_RDONLY) 被拒绝，正是鸿蒙沙箱边界的行为。
  fs.chmodSync(blocked, 0o111);
  try {
    const store = new LocalAttachmentStore({}, { dshHome: home });
    const ref = await store.saveFile({ data: new Uint8Array([1, 2, 3, 4]), name: 'probe.bin' });
    assert.match(ref.attachmentId, /^sha256:[a-f0-9]{64}$/);
    assert.equal(ref.name, 'probe.bin');
    assert.equal(ref.bytes, 4);
  } finally {
    fs.chmodSync(blocked, 0o700);
    fs.rmSync(base, { recursive: true, force: true });
  }
});
