#!/usr/bin/env node
// 静态检查：随包清单里每个 .js 文件 import/require 的裸包名，是否都在包里。
//
// 引擎的插件是按名字动态 import 的，--dump-config 只能证明插件表能解析，
// 证明不了每个包的运行期 import 都有落盘。这个脚本把两者之间的缝补上：
// 它不执行任何代码，只按 Node 的裸包名规则比对 node_modules 与清单。
//
//   node scan-imports.mjs <ship-list.txt> <node_modules> [out.txt]
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { builtinModules } from 'node:module';

const [listPath, nodeModules, outPath] = process.argv.slice(2);
if (!listPath || !nodeModules) {
  console.error('usage: scan-imports.mjs <ship-list.txt> <node_modules> [out.txt]');
  process.exit(2);
}

const files = readFileSync(listPath, 'utf8').split('\n').filter(Boolean);
const shippedPkgs = new Set();
for (const f of files) {
  const parts = f.split('/');
  shippedPkgs.add(f.startsWith('@') ? `${parts[0]}/${parts[1]}` : parts[0]);
}

const builtins = new Set(builtinModules);
// 上游 @vscode/ripgrep 只分发预编译二进制；工程里由 pack-native.sh 生成的
// 同名兼容包替换，所以它不该出现在清单里。
const REPLACED = new Set(['@vscode/ripgrep']);

const shippedFiles = new Set(files);
const missingRelatives = [];

// 相对 import 的目标文件必须在清单里：漏一个就是运行期 ERR_MODULE_NOT_FOUND。
function resolveRelative(fromRel, spec) {
  const dir = fromRel.split('/').slice(0, -1).join('/');
  const base = dir ? `${dir}/${spec}` : spec;
  const parts = [];
  for (const seg of base.split('/')) {
    if (seg === '.' || seg === '') continue;
    if (seg === '..') parts.pop();
    else parts.push(seg);
  }
  const p = parts.join('/');
  const candidates = [p, `${p}.js`, `${p}.mjs`, `${p}.cjs`, `${p}/index.js`, `${p}/index.mjs`, `${p}/index.cjs`];
  return candidates.find((c) => shippedFiles.has(c)) || null;
}
const SPEC = /(?:import\s[^'"]*?from\s*|import\s*\(\s*|require\s*\(\s*|import\s*)(['"])([^'"]+)\1/g;
const missing = new Map();

for (const rel of files) {
  if (!/\.(js|mjs|cjs)$/.test(rel)) continue;
  const abs = join(nodeModules, rel);
  let src;
  try { src = readFileSync(abs, 'utf8'); } catch { continue; }
  for (const m of src.matchAll(SPEC)) {
    const spec = m[2];
    if (!spec || spec.startsWith('node:')) continue;
    if (spec.startsWith('.')) {
      if (!resolveRelative(rel, spec)) missingRelatives.push(`${rel} -> ${spec}`);
      continue;
    }
    if (spec.startsWith('/')) continue;
    const pkg = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
    if (builtins.has(pkg) || shippedPkgs.has(pkg) || REPLACED.has(pkg)) continue;
    let exists = false;
    try { exists = statSync(join(nodeModules, pkg, 'package.json')).isFile(); } catch { exists = false; }
    if (!exists) continue; // 该包在完整树里也不存在：另有问题，交给运行时报告
    if (!missing.has(pkg)) missing.set(pkg, rel);
  }
}

const out = [...missing.keys()].sort();
if (outPath) writeFileSync(outPath, out.join('\n') + (out.length ? '\n' : ''));
console.log(`shipped packages: ${shippedPkgs.size}, files: ${files.length}`);
console.log(`imported but not shipped: ${out.length}`);
for (const pkg of out) console.log(`  ${pkg}   (first seen in ${missing.get(pkg)})`);
console.log(`relative imports with no file: ${missingRelatives.length}`);
for (const rel of missingRelatives.slice(0, 20)) console.log(`  ${rel}`);
if (missingRelatives.length > 20) console.log(`  ... 还有 ${missingRelatives.length - 20} 条`);
process.exitCode = out.length === 0 && missingRelatives.length === 0 ? 0 : 1;
