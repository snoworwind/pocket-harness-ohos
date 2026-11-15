#!/usr/bin/env node
// Static import-graph analysis of the `sdk` profile: start at the 110 mounted
// plugin entry points and follow real imports (static, dynamic, require).
import { readFileSync, writeFileSync, existsSync, statSync, readdirSync } from 'node:fs';
import { join, dirname, resolve as presolve } from 'node:path';

const W = '/mnt/c/Users/zouha/Documents/Codex/2026-11-15/ca/work';
const NM = '/var/tmp/deepseek-harmony-native/official-engine/node_modules';
const MB = (b) => (b / 1048576).toFixed(1);

const namesFile = process.argv[2] ?? 'dump-sdk-names.txt';
const outFile = process.argv[3] ?? 'import-closure.json';
const names = readFileSync(join(W, namesFile), 'utf8').split('\n').map((s) => s.trim()).filter(Boolean);

function pkgDir(name) {
  const p = join(NM, name);
  return existsSync(join(p, 'package.json')) ? p : undefined;
}
function entryFile(dir) {
  let m;
  try { m = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')); } catch { return undefined; }
  const tryPaths = (spec) => {
    if (!spec) return undefined;
    let s = spec.replace(/^\.\//, '');
    const cands = [s, s + '.js', s + '.mjs', s + '.cjs', s + '/index.js'];
    for (const c of cands) if (existsSync(join(dir, c)) && statSync(join(dir, c)).isFile()) return join(dir, c);
    return undefined;
  };
  const ex = m.exports;
  if (ex) {
    const root = ex['.'] ?? ex;
    if (typeof root === 'string') return tryPaths(root);
    if (root && typeof root === 'object') {
      for (const k of ['node', 'import', 'default', 'require']) {
        const v = root[k];
        if (typeof v === 'string') { const f = tryPaths(v); if (f) return f; }
        if (v && typeof v === 'object' && typeof v.default === 'string') { const f = tryPaths(v.default); if (f) return f; }
      }
    }
  }
  return tryPaths(m.main ?? 'index.js') ?? tryPaths('index.js');
}

const IMPORT_RES = [
  /(?:^|[\s;{(])import\s+(?:[^'"]*?\sfrom\s*)?["']([^"']+)["']/g,
  /(?:^|[\s;{(])export\s+(?:\*|\{[^}]*\})\s*(?:as\s+\w+\s*)?from\s*["']([^"']+)["']/g,
  /import\(\s*["']([^"']+)["']\s*\)/g,
  /require\(\s*["']([^"']+)["']\s*\)/g,
];
function importsOf(file) {
  let src;
  try { src = readFileSync(file, 'utf8'); } catch { return []; }
  const out = new Set();
  for (const re of IMPORT_RES) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(src))) out.add(m[1]);
  }
  return [...out];
}
function resolveSpec(spec, fromFile) {
  if (spec.startsWith('node:') || spec.startsWith('data:') || spec.startsWith('file:')) return undefined;
  if (spec.startsWith('.')) {
    const base = presolve(dirname(fromFile), spec);
    for (const c of [base, base + '.js', base + '.mjs', base + '.cjs', join(base, 'index.js')]) {
      if (existsSync(c) && statSync(c).isFile()) return { file: c };
    }
    return undefined;
  }
  // bare specifier: package (+ optional subpath)
  const parts = spec.split('/');
  const pkgName = spec.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
  const sub = spec.slice(pkgName.length).replace(/^\//, '');
  const dir = pkgDir(pkgName);
  if (!dir) return { missing: pkgName };
  if (sub) {
    // consult the package's "exports" map for the subpath first
    try {
      const m = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
      const key = './' + sub;
      let target = m.exports?.[key];
      if (target && typeof target === 'object') target = target.default ?? target.import ?? target.node;
      if (typeof target === 'string') {
        const f = join(dir, target.replace(/^\.\//, ''));
        if (existsSync(f) && statSync(f).isFile()) return { file: f, pkg: pkgName };
      }
    } catch {}
    const cands = [join(dir, sub), join(dir, sub + '.js'), join(dir, sub, 'index.js')];
    for (const c of cands) if (existsSync(c) && statSync(c).isFile()) return { file: c, pkg: pkgName };
    return { pkg: pkgName, missing: spec };
  }
  const e = entryFile(dir);
  return e ? { file: e, pkg: pkgName } : { pkg: pkgName, missing: spec };
}

const visitedFiles = new Set();
const reachedPkgs = new Map(); // name -> dir
const missing = new Set();
const queue = [];
for (const n of names) {
  const name = n.startsWith('@') ? n : '@deepseek-ai/' + n;
  const dir = pkgDir(name);
  if (!dir) { missing.add(name); continue; }
  const e = entryFile(dir);
  reachedPkgs.set(name, dir);
  if (e) queue.push(e);
}
// launcher entry
const launcher = join(NM, '@deepseek-ai/dsh/lib/bin.js');
if (existsSync(launcher)) { queue.push(launcher); reachedPkgs.set('@deepseek-ai/dsh', join(NM, '@deepseek-ai/dsh')); }

while (queue.length) {
  const f = queue.pop();
  if (visitedFiles.has(f)) continue;
  visitedFiles.add(f);
  for (const spec of importsOf(f)) {
    const r = resolveSpec(spec, f);
    if (!r) continue;
    if (r.missing) { missing.add(r.missing); continue; }
    if (r.pkg && !reachedPkgs.has(r.pkg)) reachedPkgs.set(r.pkg, pkgDir(r.pkg));
    if (r.file) queue.push(r.file);
  }
}

// sizes of reached packages (whole package, apparent)
function pkgBytes(dir) {
  let total = 0;
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    if (cur !== dir && cur.endsWith('node_modules')) continue; // nested installs handled by name resolution
    let st; try { st = statSync(cur); } catch { continue; }
    if (st.isDirectory()) { for (const e of readdirSync(cur)) stack.push(join(cur, e)); }
    else total += st.size;
  }
  return total;
}
function pkgShipBytes(dir) {
  let total = 0;
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    if (cur !== dir && cur.endsWith('node_modules')) continue;
    let st; try { st = statSync(cur); } catch { continue; }
    if (st.isDirectory()) { for (const e of readdirSync(cur)) stack.push(join(cur, e)); continue; }
    if (/\.(d\.ts|d\.mts|d\.cts|map|ts|cts|mts|md|pdb)$/.test(cur) || /\/(locale|test|tests|__tests__|fixtures|doc|docs)\//.test(cur)) continue;
    total += st.size;
  }
  return total;
}
const rows = [];
let total = 0;
let ship = 0;
for (const [name, dir] of reachedPkgs) {
  const b = pkgBytes(dir);
  const s = pkgShipBytes(dir);
  total += b; ship += s;
  rows.push({ name, bytes: b, shipBytes: s });
}
rows.sort((a, b) => b.bytes - a.bytes);
console.log('files reached:', visitedFiles.size);
console.log('packages reached:', rows.length, '->', MB(total), 'MB apparent (excl. nested node_modules)');
console.log('same, after stripping .d.ts/.map/.ts/.md/locale/tests:', MB(ship), 'MB');
console.log('top 30 reached packages:');
for (const r of rows.slice(0, 30)) console.log(String(r.bytes / 1048576).padStart(7), 'MB', r.name, '| ship', MB(r.shipBytes));
console.log('\nunresolved imports (not installed):', [...missing].join(', '));
writeFileSync(join(W, outFile), JSON.stringify({ total, rows, missing: [...missing] }, null, 1));
