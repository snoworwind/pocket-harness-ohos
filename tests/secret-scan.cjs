// 敏感文件门禁规则的单测。这里只构造测试字符串，不写真实密钥，
// 也避免测试源码本身被 --all 扫描命中。
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const SCANNER = path.join(__dirname, '..', '.githooks', 'secret-scan.mjs');
let inspect;

test.before(async () => {
  ({ inspect } = await import(pathToFileURL(SCANNER).href));
});

function rules(content, file = 'src/example.ts') {
  return inspect(file, Buffer.from(content, 'utf8')).map((issue) => issue.rule);
}

test('私钥块被拦截', () => {
  const key = '-----BEGIN ' + 'OPENSSH PRIVATE KEY-----';
  assert.deepEqual(rules(`const k = \`${key}\``), ['私钥块']);
});

test('常见云服务 token 被拦截', () => {
  assert.deepEqual(rules('id = ' + 'AKIA' + 'ABCDEFGHIJKLMNOP'), ['AWS 访问密钥']);
  assert.deepEqual(rules('token = ' + 'gh' + 'p_' + 'a'.repeat(36)), ['GitHub token']);
  assert.deepEqual(rules('key = ' + 'sk-' + 'a'.repeat(24)), ['OpenAI/DeepSeek 风格密钥']);
});

test('普通变量名和占位符不误报', () => {
  assert.deepEqual(rules('const token = process.env.DSH_TOKEN;'), []);
  assert.deepEqual(rules('password: "请填写"'), []);
  assert.deepEqual(rules('const apiKey = "";'), []);
});

test('签名文件路径被拦截', () => {
  assert.deepEqual(inspect('signing.local.profile.json5', Buffer.alloc(0)).map((i) => i.rule), ['签名配置文件']);
  assert.deepEqual(inspect('.sign/debug.p12', Buffer.alloc(0)).map((i) => i.rule), ['签名目录 .sign/', '签名/密钥扩展名']);
  assert.deepEqual(inspect('build-profile.json5', Buffer.alloc(0)).map((i) => i.rule), ['根构建配置 build-profile.json5']);
});

test('模块级 build-profile 与 .env.example 允许提交', () => {
  assert.deepEqual(inspect('entry/build-profile.json5', Buffer.from('{}')), []);
  assert.deepEqual(inspect('.env.example', Buffer.from('TOKEN=')), []);
  assert.deepEqual(inspect('.env.local', Buffer.alloc(0)).map((i) => i.rule), ['环境变量文件 .env']);
});

test('二进制文件只做文件名检查', () => {
  assert.deepEqual(inspect('assets/logo.bin', Buffer.from([0x00, 0x41, 0x4b, 0x49, 0x41])).map((i) => i.rule), []);
});

test('命中位置带行号', () => {
  const content = 'line1\nline2\nconst k = ' + 'AKIA' + 'ABCDEFGHIJKLMNOP';
  const issues = inspect('src/a.ts', Buffer.from(content));
  assert.equal(issues.length, 1);
  assert.equal(issues[0].line, 3);
});
