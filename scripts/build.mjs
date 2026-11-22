#!/usr/bin/env node
// 跨平台构建入口（Windows / macOS / Linux 通用），替代原来的 build.ps1。
//
//   node scripts/build.mjs [--deveco-home <path>] [--clean] [--force-ohpm]
//                          [--strict-runtime-manifest] [--release]
//
// 每次构建前都会按实际随包的运行时归档重算 runtime-manifest.version（哈希只在
// 构建时临时算，不落盘）；--strict-runtime-manifest（或
// DSH_STRICT_RUNTIME_MANIFEST=1）只校验不写回，供 CI/发布门禁使用：清单与
// 产物不一致时直接失败。
// --release（或 DSH_BUILD_MODE=release）会强制打开严格的清单校验：
// 发布构建不接受“先 sync 再打包”的自动修正，debug 构建行为保持不变。
//
// 只需要一个 Node 18+ 来跑这个脚本；hvigor、ohpm、SDK、JDK 都从 DevEco 安装目录里取，
// 所以 DevEco 可以用命令行工具包或完整安装，不必打开 IDE。
//
// 签名完全交给构建配置本身：签名材料写在 build-profile.json5 的 signingConfigs 里
// （本地填写、不要提交），或由 DevEco 注入。脚本不会改动任何构建配置文件。
import { existsSync, readFileSync, copyFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const option = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : undefined;
};

const isWindows = process.platform === 'win32';
const exe = (name) => (isWindows ? `${name}.exe` : name);

function fail(message) {
  console.error(`build: ${message}`);
  process.exit(1);
}

function devecoCandidates() {
  const list = [];
  if (isWindows) {
    const local = process.env.LOCALAPPDATA;
    if (local) {
      const homeFile = join(local, 'Huawei', 'DevEcoStudio6.1', '.home');
      if (existsSync(homeFile)) {
        const text = readFileSync(homeFile, 'utf8').trim();
        if (text) list.push(text);
      }
    }
    list.push('D:\\D Program Files\\DevEco Studio', 'C:\\Program Files\\Huawei\\DevEco Studio');
  } else if (process.platform === 'darwin') {
    list.push('/Applications/DevEco-Studio.app/Contents');
  } else {
    const home = homedir();
    list.push(join(home, 'deveco-studio'), '/opt/deveco-studio', '/usr/local/deveco-studio');
  }
  return list;
}

function findDeveco() {
  const explicit = option('deveco-home') ?? process.env.DEVECO_HOME;
  if (explicit) {
    if (!existsSync(join(explicit, 'tools', 'hvigor', 'bin', 'hvigorw.js'))) {
      fail(`DEVECO_HOME 下找不到 hvigor：${explicit}`);
    }
    return explicit;
  }
  for (const candidate of devecoCandidates()) {
    if (existsSync(join(candidate, 'tools', 'hvigor', 'bin', 'hvigorw.js'))) return candidate;
  }
  fail('找不到 DevEco 安装目录：用 --deveco-home 或环境变量 DEVECO_HOME 指定');
  return '';
}

const deveco = findDeveco();
const hvigor = join(deveco, 'tools', 'hvigor', 'bin', 'hvigorw.js');
const bundledNode = isWindows
  ? join(deveco, 'tools', 'node', 'node.exe')
  : join(deveco, 'tools', 'node', 'bin', 'node');
const nodeBin = existsSync(bundledNode) ? bundledNode : process.execPath;
const sdk = join(deveco, 'sdk');
const jbr = join(deveco, 'jbr');
const ohpm = join(deveco, 'tools', 'ohpm', 'bin', isWindows ? 'ohpm.bat' : 'ohpm');

const env = {
  ...process.env,
  DEVECO_SDK_HOME: sdk,
  ...(existsSync(jbr) ? { JAVA_HOME: jbr } : {})
};

function run(command, args, label) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    stdio: 'inherit',
    shell: isWindows && /\.(bat|cmd)$/i.test(command)
  });
  if (result.error) fail(`${label}: ${result.error.message}`);
  if (result.status !== 0) fail(`${label}: exit ${result.status}`);
}

// ── 构建配置 ───────────────────────────────────────────────────────────────
// build-profile.json5 被 .gitignore 排除（含证书路径与口令）；首次构建用模板生成。
const profilePath = join(root, 'build-profile.json5');
const examplePath = join(root, 'build-profile.example.json5');
if (!existsSync(profilePath) && existsSync(examplePath)) {
  copyFileSync(examplePath, profilePath);
  console.log('build: 已由 build-profile.example.json5 生成 build-profile.json5');
}

// ── 依赖 ──────────────────────────────────────────────────────────────────
if (!existsSync(join(root, 'entry', 'oh_modules', 'iec')) || flag('force-ohpm')) {
  if (!existsSync(ohpm)) fail(`找不到 ohpm：${ohpm}`);
  run(ohpm, ['install', '--all'], 'ohpm install');
}

// ── 运行时清单 ────────────────────────────────────────────────────────────
// 版本号必须跟本次真正打进 HAP 的运行时归档一致：引擎/npm/python/vim 换了却
// 忘了改 version 时，设备会命中旧 runtime 目录的 .installed，继续用旧运行时。
// 哈希不落盘：只有真正有归档的机器（打包机/本地构建）才能算，CI 上会跳过。
const runtimeManifest = join(root, 'scripts', 'runtime-manifest.mjs');
const buildMode = (option('build-mode') ?? process.env.DSH_BUILD_MODE ?? '').toLowerCase();
const releaseBuild = flag('release') || buildMode === 'release';
const strictRuntimeManifest =
  flag('strict-runtime-manifest') || releaseBuild || process.env.DSH_STRICT_RUNTIME_MANIFEST === '1';
if (releaseBuild) console.log('build: release 构建，强制校验 runtime-manifest');
run(
  process.execPath,
  [runtimeManifest, strictRuntimeManifest ? 'check' : 'sync'],
  strictRuntimeManifest ? 'runtime manifest check' : 'runtime manifest sync'
);

// ── 构建 ──────────────────────────────────────────────────────────────────
if (flag('clean')) {
  run(nodeBin, [hvigor, '--mode', 'module', '-p', 'module=entry@default', 'clean', '--no-daemon'], 'hvigor clean');
}
run(
  nodeBin,
  [hvigor, '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', 'assembleHap', '--no-daemon'],
  'hvigor assembleHap'
);

const out = join(root, 'entry', 'build', 'default', 'outputs', 'default');
const unsigned = join(out, 'entry-default-unsigned.hap');
const signed = join(out, 'entry-default-signed.hap');
if (existsSync(unsigned)) console.log(unsigned);
if (existsSync(signed)) console.log(signed);
