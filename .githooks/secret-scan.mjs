#!/usr/bin/env node
/**
 * 敏感文件门禁：提交/推送前扫描将要进入仓库的内容。
 *
 *   node .githooks/secret-scan.mjs --staged      # pre-commit：暂存区
 *   node .githooks/secret-scan.mjs --pre-push    # pre-push：本次要推送的提交
 *   node .githooks/secret-scan.mjs --all         # CI/手动：当前工作树全部受跟踪文件
 *
 * 只报告命中的规则和位置，不回显密钥内容。文件名规则命中也会直接拒绝，
 * 因为签名材料/本地配置即使内容为空也不应进入仓库。
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_CONTENT_BYTES = 8 * 1024 * 1024;
const ZERO_SHA = /^0+$/;
let root = process.cwd();

function git(args, options = {}) {
  return execFileSync('git', args, {
    encoding: 'buffer',
    maxBuffer: 64 * 1024 * 1024,
    ...options,
  });
}

function splitZ(buffer) {
  return buffer.toString('utf8').split('\0').filter((item) => item.length > 0);
}

/** 文件名本身就是敏感材料：签名、本地凭据、私钥、根构建配置。 */
const BLOCKED_PATH_RULES = [
  { name: '签名目录 .sign/', test: (p) => /(^|\/)\.sign\//i.test(p) },
  { name: '本地暂存目录 .local/', test: (p) => /(^|\/)\.local\//i.test(p) },
  { name: '签名配置文件', test: (p) => /(^|\/)signing\.(local\.)?(profile|config)\.json5?$/i.test(p) },
  { name: '本地机器配置 local.properties', test: (p) => p === 'local.properties' },
  { name: '根构建配置 build-profile.json5', test: (p) => p === 'build-profile.json5' },
  { name: '环境变量文件 .env', test: (p) => /(^|\/)\.env(\.(?!example$)[^/]+)?$/i.test(p) },
  { name: '包管理器凭据', test: (p) => /(^|\/)(\.npmrc|\.ohpmrc)$/i.test(p) },
  { name: '签名/密钥扩展名', test: (p) => /\.(p12|pfx|p7b|jks|keystore|key|ppk|cer|csr)$/i.test(p) },
  { name: 'SSH/PGP 私钥文件', test: (p) => /(^|\/)(id_(rsa|dsa|ecdsa|ed25519)|secring\.gpg)$/i.test(p) },
  { name: '开发环境附加 CA', test: (p) => /(^|\/)extra-ca\.pem$/i.test(p) },
];

/** 高置信度的凭据内容。宁可漏掉可疑值，也不把源码里的普通变量名当密钥。 */
const SECRET_CONTENT_RULES = [
  { name: '私钥块', re: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/ },
  { name: 'AWS 访问密钥', re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { name: 'GitHub token', re: /\bgh[pousr]_[A-Za-z0-9]{36,}\b/ },
  { name: 'GitHub fine-grained token', re: /\bgithub_pat_[A-Za-z0-9_]{60,}\b/ },
  { name: 'OpenAI/DeepSeek 风格密钥', re: /\bsk-[A-Za-z0-9]{24,}\b/ },
  { name: 'Slack token', re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ },
  { name: 'Google API key', re: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  { name: 'Huawei/其他常见 bearer token', re: /\bBearer\s+[A-Za-z0-9._~+/-]{32,}=*\b/ },
];

/** @param {string} file @param {Buffer | null} content */
function inspect(file, content) {
  const normalized = file.replace(/\\/g, '/');
  const issues = [];
  for (const rule of BLOCKED_PATH_RULES) {
    if (rule.test(normalized)) issues.push({ file: normalized, rule: rule.name });
  }
  if (content === null || content.length === 0 || content.length > MAX_CONTENT_BYTES) return issues;
  if (content.indexOf(0) !== -1) return issues; // 二进制只看文件名
  const text = content.toString('utf8');
  for (const rule of SECRET_CONTENT_RULES) {
    const match = rule.re.exec(text);
    if (match === null) continue;
    const line = text.slice(0, match.index).split('\n').length;
    issues.push({ file: normalized, rule: rule.name, line });
  }
  return issues;
}

function scanStaged() {
  const files = splitZ(git(['diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z']));
  return scanFiles(files, (file) => {
    try { return git(['show', `:${file}`]); } catch { return null; }
  });
}

function scanAll() {
  const files = splitZ(git(['ls-files', '-z']));
  return scanFiles(files, (file) => {
    try { return readFileSync(path.join(root, file)); } catch { return null; }
  });
}

function scanFiles(files, read) {
  const issues = [];
  for (const file of files) issues.push(...inspect(file, read(file)));
  return issues;
}

function scanOutgoing() {
  let stdin = '';
  try { stdin = readFileSync(0, 'utf8'); } catch { /* 交互式运行没有 stdin */ }
  const lines = stdin.split('\n').map((line) => line.trim()).filter(Boolean);
  if (lines.length === 0) return [];
  const issues = [];
  const seen = new Set();
  for (const line of lines) {
    const [, localSha, , remoteSha] = line.split(/\s+/);
    if (!localSha || ZERO_SHA.test(localSha)) continue;
    let files;
    if (!remoteSha || ZERO_SHA.test(remoteSha)) {
      // 新分支：扫描该提交的完整树，避免第一次推送绕过门禁。
      files = splitZ(git(['ls-tree', '-r', '--name-only', '-z', localSha]));
    } else {
      try {
        files = splitZ(git(['diff', '--name-only', '--diff-filter=ACMR', '-z', `${remoteSha}..${localSha}`]));
      } catch {
        files = splitZ(git(['ls-tree', '-r', '--name-only', '-z', localSha]));
      }
    }
    for (const file of files) {
      if (seen.has(`${localSha}:${file}`)) continue;
      seen.add(`${localSha}:${file}`);
      let content = null;
      try { content = git(['show', `${localSha}:${file}`]); } catch { /* 目录/子模块 */ }
      issues.push(...inspect(file, content));
    }
  }
  return issues;
}

function main() {
  const mode = process.argv[2] || '--staged';
  if (mode !== '--staged' && mode !== '--pre-push' && mode !== '--all') {
    console.error(`secret-scan: 未知模式 ${mode}`);
    process.exit(2);
  }
  root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  process.chdir(root);

  const issues = mode === '--staged' ? scanStaged() : mode === '--pre-push' ? scanOutgoing() : scanAll();
  if (issues.length === 0) {
    if (mode === '--all') console.log('secret-scan: 未发现敏感文件');
    process.exit(0);
  }

  console.error('secret-scan: 检测到敏感文件，已阻止本次操作：');
  for (const issue of issues) {
    const location = issue.line === undefined ? issue.file : `${issue.file}:${issue.line}`;
    console.error(`  - ${location}  [${issue.rule}]`);
  }
  console.error('\n请把上述文件移出版本控制（加入 .gitignore），或确认后从暂存区/提交中删除。');
  console.error('如果确认是误报，可临时使用 git commit/push --no-verify 绕过；不建议在共享分支上这样做。');
  process.exit(1);
}

export { inspect };

const invokedPath = process.argv[1] === undefined ? '' : path.resolve(process.argv[1]);
const modulePath = fileURLToPath(import.meta.url);
const invoked = process.platform === 'win32'
  ? invokedPath.toLowerCase() === modulePath.toLowerCase()
  : invokedPath === modulePath;
if (invoked) main();
