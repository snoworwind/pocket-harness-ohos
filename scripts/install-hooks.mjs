#!/usr/bin/env node
/**
 * 启用仓库自带的 Git 门禁：把 core.hooksPath 指向 .githooks。
 * 只需在每台开发机执行一次。
 */
import { execFileSync } from 'node:child_process';
import { chmodSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
execFileSync('git', ['-C', root, 'config', 'core.hooksPath', '.githooks'], { stdio: 'inherit' });

if (process.platform !== 'win32') {
  for (const hook of ['pre-commit', 'pre-push']) {
    try { chmodSync(path.join(root, '.githooks', hook), 0o755); } catch { /* mode 已正确 */ }
  }
}

console.log('已启用敏感文件门禁：core.hooksPath=.githooks');
console.log('手动扫描：node .githooks/secret-scan.mjs --all');
