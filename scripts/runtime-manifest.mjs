#!/usr/bin/env node
// 运行时清单的版本号由「实际随包字节」决定，而不是由人记着手改。
//
//   node scripts/runtime-manifest.mjs sync    # 重算并写回 runtime-manifest.json
//   node scripts/runtime-manifest.mjs check   # 只校验，过期则退出 1（CI/发布用）
//   node scripts/runtime-manifest.mjs print   # 打印按当前字节算出的版本号
//
// 摘要输入（全部按内容、不按绝对路径，保证换机器/换目录结果一致）：
//   - schema 标记
//   - engineVersion / nodeVersion
//   - commands 列表（按命令名排序，含 library/entry/arity）
//   - rawfile/tools/official-engine.tar.gz
//   - rawfile/tools/npm.tar.gz
//   - entry/libs 下所有 *.so / *.so.*（按相对路径排序，覆盖所有 ABI）
//
// 不把应用 versionName 算进去：只改 ArkTS/界面时复用旧运行时是刻意的。
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = join(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'tools', 'runtime-manifest.json');
const toolsDir = dirname(manifestPath);
const libsDir = join(root, 'entry', 'libs');

/** @param {string} message */
function fail(message) {
  console.error(`runtime-manifest: ${message}`);
  process.exit(1);
}

/** @param {string} path @param {string} label */
function requireFile(path, label) {
  if (!existsSync(path) || !statSync(path).isFile()) fail(`找不到${label}：${path}`);
}

/** @param {string} value */
function toPosix(value) {
  // 摘要里的路径标签必须与构建机平台无关：Windows 用 `\`，Linux 用 `/`。
  return value.replace(/\\/g, '/');
}

/** @param {string} a @param {string} b */
function compareBytes(a, b) {
  // 不能用 localeCompare：Windows 的区域设置与 Linux/C locale 排序不同，
  // 同一批随包字节会算出两个不同的 manifest.version（违反可复现性）。
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

/** @param {string} dir @returns {string[]} */
function listSoFiles(dir) {
  const out = [];
  const walk = (current) => {
    for (const name of readdirSync(current)) {
      const path = join(current, name);
      const stat = statSync(path);
      if (stat.isDirectory()) { walk(path); continue; }
      if (/\.so(\.\d+)*$/.test(name)) out.push(path);
    }
  };
  if (!existsSync(dir)) fail(`找不到原生库目录：${dir}`);
  walk(dir);
  return out.sort((a, b) => compareBytes(toPosix(relative(root, a)), toPosix(relative(root, b))));
}

/** @param {import('node:crypto').Hash} hash @param {string} label @param {string|Buffer} value */
function update(hash, label, value) {
  hash.update(label);
  hash.update('\0');
  hash.update(value);
  hash.update('\0');
}

/** @param {import('node:crypto').Hash} hash @param {string} label @param {string} path */
async function updateFile(hash, label, path) {
  update(hash, `${label}:path`, toPosix(relative(root, path)));
  hash.update(`${label}:content`);
  hash.update('\0');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  hash.update('\0');
}

/** @param {string} path @returns {Promise<string>} */
async function fileSha256(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

// pack-native.sh 在生成 official-engine.tar.gz 时同时写 official-engine.sha256
// （内容为 "<sha256>  official-engine.tar.gz"）。这里核对两者一致，防止归档被
// 替换/拼接后仍沿用旧清单。
async function verifyEngineChecksum() {
  const archive = join(toolsDir, 'official-engine.tar.gz');
  const sums = join(toolsDir, 'official-engine.sha256');
  requireFile(archive, '运行时归档 official-engine.tar.gz');
  requireFile(sums, '完整性清单 official-engine.sha256（pack-native.sh 生成）');
  const text = readFileSync(sums, 'utf8').trim();
  const expected = /^([0-9a-f]{64})\s+official-engine\.tar\.gz$/i.exec(text);
  if (expected === null) {
    fail(`official-engine.sha256 格式不合法：${JSON.stringify(text.slice(0, 120))}`);
  }
  const actual = await fileSha256(archive);
  if (actual !== expected[1].toLowerCase()) {
    fail(`official-engine.tar.gz SHA-256 与清单不一致（清单 ${expected[1]}，实际 ${actual}）`);
  }
}

/** @param {any} manifest @returns {Promise<string>} */
async function expectedVersion(manifest) {
  if (typeof manifest.engineVersion !== 'string' || !/^[a-zA-Z0-9.-]+$/.test(manifest.engineVersion)) {
    fail('manifest.engineVersion 缺失或含非法字符');
  }
  if (typeof manifest.nodeVersion !== 'string' || !/^[a-zA-Z0-9.-]+$/.test(manifest.nodeVersion)) {
    fail('manifest.nodeVersion 缺失或含非法字符');
  }
  if (!Array.isArray(manifest.commands) || manifest.commands.length === 0) fail('manifest.commands 为空');

  const hash = createHash('sha256');
  update(hash, 'schema', 'dsh-runtime-v2');
  update(hash, 'engineVersion', manifest.engineVersion);
  update(hash, 'nodeVersion', manifest.nodeVersion);
  const commands = manifest.commands
    .map((command) => ({
      name: String(command.name),
      library: String(command.library),
      entry: String(command.entry),
      arity: command.arity === 3 ? 3 : 2,
      elfStub: command.elfStub === true,
    }))
    .sort((a, b) => compareBytes(a.name, b.name));
  update(hash, 'commands', JSON.stringify(commands));

  await verifyEngineChecksum();
  for (const name of ['official-engine.tar.gz', 'npm.tar.gz', 'python-stdlib.tar', 'vim-runtime.tar.gz']) {
    const path = join(toolsDir, name);
    requireFile(path, `运行时归档 ${name}`);
    await updateFile(hash, `archive:${name}`, path);
  }
  // 设备端会从 rawfile 写出这两份 ELF 启动桩；只有存在时才计入，x86/arm64
  // 只带其中一份的构建树也能算出一致的摘要。
  for (const name of ['iec-exec-stub-arm64', 'iec-exec-stub-x86_64']) {
    const path = join(toolsDir, name);
    if (existsSync(path)) await updateFile(hash, `stub:${name}`, path);
  }
  for (const path of listSoFiles(libsDir)) await updateFile(hash, `so:${toPosix(relative(libsDir, path))}`, path);

  return `${manifest.engineVersion}-${hash.digest('hex').slice(0, 12)}`;
}

/** @returns {any} */
function readManifest() {
  requireFile(manifestPath, ' runtime-manifest.json');
  try {
    return JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    fail(`runtime-manifest.json 不是合法 JSON：${error.message}`);
  }
}

/** @param {string} version */
function writeVersion(version) {
  const text = readFileSync(manifestPath, 'utf8');
  const pattern = /("version"\s*:\s*)"[^"]*"/;
  if (!pattern.test(text)) fail('runtime-manifest.json 里找不到顶层 version 字段');
  const next = text.replace(pattern, `$1${JSON.stringify(version)}`);
  writeFileSync(manifestPath, next, 'utf8');
}

async function main() {
  const mode = process.argv[2] ?? 'sync';
  const manifest = readManifest();
  const version = await expectedVersion(manifest);
  const current = typeof manifest.version === 'string' ? manifest.version : '';

  if (mode === 'print') {
    console.log(version);
    return;
  }
  if (mode === 'check') {
    if (current !== version) {
      console.error(`runtime-manifest: 版本过期：清单是 ${JSON.stringify(current)}，实际字节应为 ${JSON.stringify(version)}`);
      console.error('runtime-manifest: 运行 `node scripts/runtime-manifest.mjs sync` 后提交 runtime-manifest.json');
      process.exit(1);
    }
    console.log(`runtime-manifest: OK ${version}`);
    return;
  }
  if (mode !== 'sync') fail(`未知模式 ${JSON.stringify(mode)}（可用：sync / check / print）`);

  if (current === version) {
    console.log(`runtime-manifest: 未变化 ${version}`);
    return;
  }
  writeVersion(version);
  console.log(`runtime-manifest: 已更新 ${current === '' ? '(空)' : current} -> ${version}`);
  console.log('runtime-manifest: 请把 entry/src/main/resources/rawfile/tools/runtime-manifest.json 的变更一起提交');
}

await main();
