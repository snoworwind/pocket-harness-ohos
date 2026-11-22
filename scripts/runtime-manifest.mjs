#!/usr/bin/env node
// 运行时清单的版本号由「实际随包字节」决定，而不是由人记着手改。
//
//   node scripts/runtime-manifest.mjs sync    # 按当前归档重算并写回 version
//   node scripts/runtime-manifest.mjs check   # 只校验，过期则退出 1（CI/发布用）
//   node scripts/runtime-manifest.mjs print   # 打印按当前归档算出的版本号
//
// 哈希不用任何人手算：pack-native.sh 和 build.mjs 都会自动调用 sync。
// 摘要输入只有两样：
//   - manifest 自身的 engineVersion / nodeVersion / commands；
//   - 四个运行时归档（engine/npm/python-stdlib/vim，外加可选的 ELF 启动桩）的字节。
//
// 摘要域刻意只覆盖会被解包进 runtime-<version>/ 的东西：
//   * entry/libs/<abi>/*.so 不计入——它们直接从 HAP 的 libs 加载，启动器每次
//     ensure() 都按 commands 重写；而且 hvigor 打包会 strip，构建树里的字节
//     本来就不是设备字节；
//   * 壳层插件（harmony-compat / 终端）不计入——随 rawfile 分发、每次启动重新
//     同步，pack-native.sh 也不再把它们打进引擎归档。
// 所以只有换 engine/npm/python-stdlib/vim 才需要重算版本，而且是在构建/打包时
// 自动完成；改原生库、改插件、只改 UI 都不需要碰这个文件。
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = resolve(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'tools', 'runtime-manifest.json');
const toolsDir = dirname(manifestPath);

/** 解包进 runtime-<version>/ 的归档；它们的字节决定版本。 */
export const ARTIFACTS = ['official-engine.tar.gz', 'npm.tar.gz', 'python-stdlib.tar', 'vim-runtime.tar.gz'];
/** 可选 ELF 启动桩，只在部分构建树里存在。 */
export const STUBS = ['iec-exec-stub-arm64', 'iec-exec-stub-x86_64'];

/** @param {string} message */
function fail(message) {
  console.error(`runtime-manifest: ${message}`);
  process.exit(1);
}

/** @param {string} a @param {string} b */
function compareBytes(a, b) {
  // 不能用 localeCompare：Windows 的区域设置与 Linux/C locale 排序不同，
  // 同一批随包字节会算出两个不同的 manifest.version（违反可复现性）。
  return a < b ? -1 : a > b ? 1 : 0;
}

/** @param {import('node:crypto').Hash} hash @param {string} label @param {string} value */
function update(hash, label, value) {
  hash.update(label);
  hash.update('\0');
  hash.update(value);
  hash.update('\0');
}

/** @param {string} path @returns {Promise<string>} */
async function fileSha256(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

/**
 * 版本是 manifest 元数据 + 归档摘要的纯函数。artifacts 由调用方从实际文件算出来，
 * 不落进清单；这样清单里没有任何需要人工维护的哈希。
 * @param {any} manifest
 * @param {Record<string, string>} artifacts
 * @returns {string}
 */
export function runtimeVersion(manifest, artifacts) {
  if (typeof manifest.engineVersion !== 'string' || !/^[a-zA-Z0-9.-]+$/.test(manifest.engineVersion)) {
    throw new Error('manifest.engineVersion 缺失或含非法字符');
  }
  if (typeof manifest.nodeVersion !== 'string' || !/^[a-zA-Z0-9.-]+$/.test(manifest.nodeVersion)) {
    throw new Error('manifest.nodeVersion 缺失或含非法字符');
  }
  if (!Array.isArray(manifest.commands) || manifest.commands.length === 0) {
    throw new Error('manifest.commands 为空');
  }
  const normalized = {};
  for (const name of [...ARTIFACTS, ...STUBS].sort(compareBytes)) {
    const value = artifacts[name];
    if (value === undefined) continue;
    if (!/^[0-9a-f]{64}$/i.test(value)) throw new Error(`归档 ${name} 的 sha256 不合法`);
    normalized[name] = value.toLowerCase();
  }
  for (const name of ARTIFACTS) {
    if (normalized[name] === undefined) throw new Error(`缺少归档 ${name} 的 sha256`);
  }
  if (Object.keys(normalized).some((name) => !ARTIFACTS.includes(name) && !STUBS.includes(name))) {
    throw new Error('归档摘要里出现未知条目');
  }
  const commands = manifest.commands
    .map((command) => ({
      name: String(command.name),
      library: String(command.library),
      entry: String(command.entry),
      arity: command.arity === 3 ? 3 : 2,
      elfStub: command.elfStub === true,
    }))
    .sort((a, b) => compareBytes(a.name, b.name));

  const hash = createHash('sha256');
  update(hash, 'schema', 'dsh-runtime-v2');
  update(hash, 'engineVersion', manifest.engineVersion);
  update(hash, 'nodeVersion', manifest.nodeVersion);
  update(hash, 'commands', JSON.stringify(commands));
  update(hash, 'artifacts', JSON.stringify(normalized));
  return `${manifest.engineVersion}-${hash.digest('hex').slice(0, 12)}`;
}

// pack-native.sh 在生成 official-engine.tar.gz 时同时写 official-engine.sha256
// （内容为 "<sha256>  official-engine.tar.gz"）。这里核对两者一致，防止归档被
// 替换/拼接后仍沿用旧清单。
/** @param {string} actual */
function verifyEngineChecksum(actual) {
  const sums = resolve(toolsDir, 'official-engine.sha256');
  if (!existsSync(sums)) fail('找不到完整性清单 official-engine.sha256（pack-native.sh 生成）');
  const text = readFileSync(sums, 'utf8').trim();
  const expected = /^([0-9a-f]{64})\s+official-engine\.tar\.gz$/i.exec(text);
  if (expected === null) fail(`official-engine.sha256 格式不合法：${JSON.stringify(text.slice(0, 120))}`);
  if (actual !== expected[1].toLowerCase()) {
    fail(`official-engine.tar.gz 的字节与 official-engine.sha256 不一致（清单 ${expected[1]}，实际 ${actual}）`);
  }
}

/** @returns {any} */
function readManifest() {
  if (!existsSync(manifestPath) || !statSync(manifestPath).isFile()) fail(`找不到 runtime-manifest.json：${manifestPath}`);
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
  writeFileSync(manifestPath, text.replace(pattern, `$1${JSON.stringify(version)}`), 'utf8');
}

async function main() {
  const mode = process.argv[2] ?? 'sync';
  if (mode !== 'sync' && mode !== 'check' && mode !== 'print') {
    fail(`未知模式 ${JSON.stringify(mode)}（可用：sync / check / print）`);
  }
  const manifest = readManifest();
  const present = ARTIFACTS.filter((name) => existsSync(resolve(toolsDir, name)));
  if (present.length > 0 && present.length < ARTIFACTS.length) {
    const missing = ARTIFACTS.filter((name) => !present.includes(name));
    fail(`运行时归档不完整：缺少 ${missing.join(', ')}；请先跑 scripts/pack-native.sh 或补齐归档`);
  }
  if (present.length === 0) {
    // 归档是构建产物、不入库：CI/clean checkout 上没有东西可算，只能跳过。
    if (mode === 'check') {
      console.log('runtime-manifest: 未找到运行时归档（构建产物），跳过校验；发布前在打包机执行 check');
      return;
    }
    fail('缺少运行时归档（构建产物，不入库）：请在打包机运行 scripts/pack-native.sh 或用 build.mjs 构建');
  }

  const artifacts = {};
  for (const name of ARTIFACTS) artifacts[name] = await fileSha256(resolve(toolsDir, name));
  for (const name of STUBS) {
    const path = resolve(toolsDir, name);
    if (existsSync(path)) artifacts[name] = await fileSha256(path);
  }
  verifyEngineChecksum(artifacts['official-engine.tar.gz']);

  let version;
  try {
    version = runtimeVersion(manifest, artifacts);
  } catch (error) {
    fail(error.message);
  }
  const current = typeof manifest.version === 'string' ? manifest.version : '';

  if (mode === 'print') {
    console.log(version);
    return;
  }
  if (mode === 'check') {
    if (current !== version) {
      console.error(`runtime-manifest: 版本过期：清单是 ${JSON.stringify(current)}，按当前归档应为 ${JSON.stringify(version)}`);
      console.error('runtime-manifest: 运行 `node scripts/runtime-manifest.mjs sync` 后提交 runtime-manifest.json');
      process.exit(1);
    }
    console.log(`runtime-manifest: OK ${version}`);
    return;
  }
  if (current === version) {
    console.log(`runtime-manifest: 未变化 ${version}`);
    return;
  }
  writeVersion(version);
  console.log(`runtime-manifest: 已更新 ${current === '' ? '(空)' : current} -> ${version}`);
  console.log('runtime-manifest: 请把 entry/src/main/resources/rawfile/tools/runtime-manifest.json 一起提交');
}

const invokedDirectly = process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) await main();
