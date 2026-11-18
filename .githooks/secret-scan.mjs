#!/usr/bin/env node
/**
 * 敏感文件门禁：提交/推送前扫描将要进入仓库的内容。
 *
 *   node .githooks/secret-scan.mjs --staged      # pre-commit：暂存区
 *   node .githooks/secret-scan.mjs --pre-push    # pre-push：本次要推送的提交
 *   node .githooks/secret-scan.mjs --all         # CI/手动：当前工作树全部受跟踪文件
 *   node .githooks/secret-scan.mjs --history     # CI/手动：历史提交（默认最近 200 个）
 *   SECRET_SCAN_HISTORY_LIMIT=500 ... --history  # 调整历史扫描范围
 *
 * 只报告命中的规则和位置，不回显密钥内容。文件名规则命中也会直接拒绝，
 * 因为签名材料/本地配置即使内容为空也不应进入仓库。
 * 提交信息也走内容规则（历史扫描与 pre-push 都会检查）。
 */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_CONTENT_BYTES = 8 * 1024 * 1024;
const DEFAULT_HISTORY_LIMIT = 200;
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
  // 私钥：PEM 的常见种类（含 ENCRYPTED）都拦截，规则名保持不变以兼容既有测试。
  {
    name: '私钥块',
    re: /-----BEGIN (?:ENCRYPTED |RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/,
  },
  { name: 'AWS 访问密钥', re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { name: 'GitHub token', re: /\bgh[pousr]_[A-Za-z0-9]{36,}\b/ },
  { name: 'GitHub fine-grained token', re: /\bgithub_pat_[A-Za-z0-9_]{60,}\b/ },
  { name: 'GitLab token', re: /\bglpat-[A-Za-z0-9_-]{20,}\b/ },
  { name: 'OpenAI/DeepSeek 风格密钥', re: /\bsk-[A-Za-z0-9]{24,}\b/ },
  { name: 'OpenAI project key', re: /\bsk-proj-[A-Za-z0-9_-]{20,}\b/ },
  // 华为云：AK/SK 常见形态（显式 huawei/hw 前缀的赋值，或临时凭证 AK./SK. 形态）。
  {
    name: '华为云 AK/SK',
    re: /\b(?:huawei|hw|huaweicloud)[_-]?(?:access[_-]?key(?:[_-]?id)?|secret[_-]?(?:access[_-]?)?key|ak|sk)\s*[:=]\s*["']?[A-Za-z0-9/+]{16,}/i,
  },
  { name: '华为云临时凭证 AK./SK.', re: /\b(?:AK|SK)\.[A-Za-z0-9]{20,}\b/ },
  // 其它常见云厂商/服务 token。
  { name: '阿里云 AccessKey', re: /\bLTAI[A-Za-z0-9]{12,}\b/ },
  { name: '腾讯云 SecretId', re: /\bAKID[A-Za-z0-9]{32,}\b/ },
  { name: 'Slack token', re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ },
  { name: 'Google API key', re: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  { name: 'Google OAuth token', re: /\bya29\.[0-9A-Za-z_-]{20,}\b/ },
  { name: 'Stripe secret key', re: /\bsk_(?:live|test)_[0-9A-Za-z]{16,}\b/ },
  { name: 'npm token', re: /\bnpm_[A-Za-z0-9]{36,}\b/ },
  { name: 'HuggingFace token', re: /\bhf_[A-Za-z0-9]{30,}\b/ },
  { name: 'SendGrid token', re: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/ },
  { name: 'Huawei/其他常见 bearer token', re: /\bBearer\s+[A-Za-z0-9._~+/-]{32,}=*\b/ },
];

/**
 * 历史扫描的已知、已处置条目：只豁免「该路径 + 该 blob 的精确 SHA-256」，
 * 同一个路径以不同内容再次出现时仍会被拦截。
 *
 * - `entry/src/main/resources/rawfile/harmony/extra-ca.pem`：开发环境附加 CA
 *   的**公开证书**（Kaspersky Anti-Virus 根证书，1273 字节，不含私钥），
 *   随 94f69d1 移出版本库并加入 .gitignore；保留在此仅为让历史扫描可运行。
 * - `build-profile.json5`：初始化阶段的两份模板（804/814 字节，无
 *   storePassword/keyPassword/certpath），随 ccd16b9 移出版本库；只豁免
 *   这两个历史 blob，任何带签名材料的版本仍会被拦截。
 */
const KNOWN_HISTORICAL_BLOBS = new Map([
  [
    'entry/src/main/resources/rawfile/harmony/extra-ca.pem',
    new Set(['62f5af5c6af54b295d7b5779fdaaef97ba71405fbbc4edea568da1b123bbcc9d']),
  ],
  [
    'build-profile.json5',
    new Set([
      '2c1886d79932e8c59a3a637a408de30eae15d99e6cc07d30f536128b37dfa817',
      'e99ac59bb1b40ae45fffc7bcd7aad981538fb7a398e0a03ebc4fc573dded6c40',
    ]),
  ],
]);

/** @param {string} file @param {Buffer | null} content */
function isKnownHistoricalBlob(file, content) {
  if (content === null) return false;
  const allowed = KNOWN_HISTORICAL_BLOBS.get(file.replace(/\\/g, '/'));
  if (!allowed) return false;
  return allowed.has(createHash('sha256').update(content).digest('hex'));
}

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

/** 提交信息也可能带密钥（例如粘贴 token 当说明）。 */
function scanCommitMessage(sha) {
  try {
    const message = git(['log', '-1', '--format=%B', sha]);
    return inspect(`commit ${sha} (message)`, message);
  } catch {
    return [];
  }
}

/**
 * 扫描单个提交新增/修改的 blob，并检查提交信息。
 * 密钥在中间提交加入、后续提交删除时，只看最终树会漏掉。
 */
function scanCommit(sha, seen, issues) {
  issues.push(...scanCommitMessage(sha));
  let files = [];
  try {
    files = splitZ(git(['diff-tree', '-r', '-m', '--no-commit-id', '--name-only', '-z', '--diff-filter=ACMR', sha]));
    // 根提交没有 diff-tree 父节点，退回 ls-tree。
    if (files.length === 0) files = splitZ(git(['ls-tree', '-r', '--name-only', '-z', sha]));
  } catch {
    return;
  }
  for (const file of files) {
    const key = `${sha}:${file}`;
    if (seen.has(key)) continue;
    seen.add(key);
    let content = null;
    try { content = git(['show', `${sha}:${file}`]); } catch { /* 目录/子模块 */ }
    if (isKnownHistoricalBlob(file, content)) continue;
    issues.push(...inspect(file, content));
  }
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

    let commits = [];
    if (remoteSha && !ZERO_SHA.test(remoteSha)) {
      try { commits = git(['rev-list', '--reverse', `${remoteSha}..${localSha}`]).toString('utf8').split('\n').filter(Boolean); } catch { commits = []; }
    }
    if (commits.length === 0) {
      // 新分支：必须扫推送范围内的每个提交，而不是只看 tip 树，否则中间提交
      // 里出现又删除的密钥会被放过。
      try {
        commits = git(['rev-list', '--reverse', localSha, '--not', '--remotes'])
          .toString('utf8').split('\n').filter(Boolean);
      } catch {
        commits = [];
      }
      if (commits.length === 0) commits = [localSha];
    }
    for (const sha of commits) scanCommit(sha, seen, issues);
  }
  return issues;
}

/** 历史扫描：默认最近 200 个提交，可用 SECRET_SCAN_HISTORY_LIMIT 调整。 */
function scanHistory() {
  const raw = Number(process.env.SECRET_SCAN_HISTORY_LIMIT ?? DEFAULT_HISTORY_LIMIT);
  const limit = Number.isFinite(raw) && raw > 0 ? Math.min(Math.floor(raw), 10000) : DEFAULT_HISTORY_LIMIT;
  let shas = [];
  try {
    shas = git(['rev-list', '--no-merges', `-n`, String(limit), 'HEAD'])
      .toString('utf8').split('\n').filter(Boolean);
  } catch {
    return [];
  }
  const issues = [];
  const seen = new Set();
  for (const sha of shas) scanCommit(sha, seen, issues);
  return issues;
}

function main() {
  const rawMode = process.argv[2] || '--staged';
  const mode = rawMode.split('=')[0];
  if (mode !== '--staged' && mode !== '--pre-push' && mode !== '--all' && mode !== '--history') {
    console.error(`secret-scan: 未知模式 ${rawMode}`);
    process.exit(2);
  }
  root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  process.chdir(root);

  const issues = mode === '--staged' ? scanStaged()
    : mode === '--pre-push' ? scanOutgoing()
    : mode === '--history' ? scanHistory()
    : scanAll();
  if (issues.length === 0) {
    if (mode === '--all') console.log('secret-scan: 未发现敏感文件');
    else if (mode === '--history') console.log('secret-scan: 历史扫描完成，未发现敏感内容');
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
