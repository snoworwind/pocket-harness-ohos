#!/usr/bin/env node
// 从 sdk profile 的 --dump-config 输出计算打包文件清单。
//
//   node ship-from-dump.mjs <dump.yml> <node_modules> <out.txt>
//
// 与旧的 import 闭包法不同，这里以「实际挂载的插件包」为根，沿每个包的
// dependencies 递归取并集：dsh-base 这类按名字解析的 profile bundle 不会再漏。
// 只删除文档、类型声明、源码映射、测试与外部平台预编译二进制；package.json 全留。
import { readFileSync, writeFileSync, statSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';

const [dumpPath, nodeModules, outPath, ...extraRoots] = process.argv.slice(2);
if (!dumpPath || !nodeModules || !outPath) {
  console.error('usage: ship-from-dump.mjs <dump.yml> <node_modules> <out.txt> [extra-root...]');
  process.exit(2);
}

const dump = readFileSync(dumpPath, 'utf8');
const roots = new Set();
for (const line of dump.split('\n')) {
  const m = line.match(/name:\s*'([^']+)'/);
  if (m && m[1].startsWith('@')) roots.add(m[1]);
}
for (const extra of extraRoots) {
  if (extra.startsWith('@')) roots.add(extra);
}
// dsh 本身（bin.js 与 profile 模板）也要在包里。
roots.add('@deepseek-ai/dsh');

// 上游包只用来解析 rg 路径，且只分发预编译二进制；工程里换成自写兼容包。
const REPLACED = new Set(['@vscode/ripgrep']);

const seen = new Set();
const queue = [...roots];
while (queue.length) {
  const name = queue.pop();
  if (seen.has(name) || REPLACED.has(name)) continue;
  seen.add(name);
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(join(nodeModules, name, 'package.json'), 'utf8'));
  } catch {
    console.error(`跳过无法读取的包：${name}`);
    continue;
  }
  for (const dep of Object.keys(manifest.dependencies || {})) queue.push(dep);
  // peerDependencies 是真正的运行期依赖（例如 dsh-agent 依赖 dsh-scope），
  // 只走 dependencies 会漏掉它们，真机启动时报 Cannot find package。
  for (const dep of Object.keys(manifest.peerDependencies || {})) {
    if (manifest.peerDependenciesMeta?.[dep]?.optional) continue;
    queue.push(dep);
  }
  for (const dep of Object.keys(manifest.optionalDependencies || {})) queue.push(dep);
}

// 只删「肯定不是运行期代码」的东西。
//
// 以前这里还删 locale(s)、doc(s)、test(s)，结果踩了两次坑：
//   * yaml 的 dist/doc/directives.js 是运行期代码；
//   * 嵌套安装的 zod/node_modules/zod/v4/locales/index.js 是运行期代码。
// 现在只留 .d.ts / .map / .ts 源码 / 文档 / pdb / 外部平台预编译包，
// 其余一律保留——多几十兆，换掉一整类「真机上找不到模块」的问题。
const SKIP_FILE = /\.(d\.ts|d\.mts|d\.cts|map|ts|cts|mts|md|pdb)$/;
const SKIP_DIR = /(^|\/)prebuilds(\/|$)/;
const SKIP_BINARY = /\.(node|so|so\.\d+|dylib|dll|exe|a)$/;

const files = [];
const missing = [];
function walk(dir, pkg, rel) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    const relPath = rel ? `${rel}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      if (SKIP_DIR.test(relPath)) continue;
      walk(path, pkg, relPath);
      continue;
    }
    if (entry.name === 'package.json') {
      files.push(`${pkg}/${relPath}`);
      continue;
    }
    if (SKIP_FILE.test(entry.name)) continue;
    if (SKIP_BINARY.test(entry.name)) continue;
    let st;
    try { st = statSync(path); } catch { continue; }
    if (!st.isFile()) continue;
    files.push(`${pkg}/${relPath}`);
  }
}

for (const name of [...seen].sort()) {
  const dir = join(nodeModules, name);
  try {
    statSync(dir);
  } catch {
    missing.push(name);
    continue;
  }
  walk(dir, name, '');
}

files.sort();
writeFileSync(outPath, files.join('\n') + '\n');
console.log(`packages: ${seen.size}, files: ${files.length}`);
if (missing.length) console.log(`missing packages: ${missing.join(', ')}`);
