#!/usr/bin/env node
// Emit the shippable file list for the sdk import closure (paths relative to NM).
import { readFileSync, writeFileSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const W = process.env.ENGINE_PRUNE_WORK ?? process.cwd();
const NM = process.env.ENGINE_NODE_MODULES ?? '/var/tmp/deepseek-harmony-native/official-engine/node_modules';
const im = JSON.parse(readFileSync(join(W, process.argv[2] ?? 'import-closure.json'), 'utf8'));
const out = [];
for (const r of im.rows) {
  const root = join(NM, r.name);
  const stack = [root];
  while (stack.length) {
    const cur = stack.pop();
    if (cur !== root && cur.endsWith('node_modules')) continue;
    let st; try { st = statSync(cur); } catch { continue; }
    if (st.isDirectory()) { for (const e of readdirSync(cur)) stack.push(join(cur, e)); continue; }
    if (/\.(d\.ts|d\.mts|d\.cts|map|ts|cts|mts|md|pdb)$/.test(cur) || /\/(locale|test|tests|__tests__|fixtures|doc|docs)\//.test(cur)) continue;
    out.push(cur.replace(NM + '/', ''));
  }
}
writeFileSync(join(W, process.argv[3] ?? 'ship-files.txt'), out.join('\n') + '\n');
console.log(out.length, 'files');
