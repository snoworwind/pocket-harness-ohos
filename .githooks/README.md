# 敏感文件门禁

仓库自带的 Git 钩子会阻止把签名材料、本地凭据、私钥和常见 API token 提交或推送。

## 启用

每台开发机执行一次：

```bash
node scripts/install-hooks.mjs
```

它等价于：

```bash
git config core.hooksPath .githooks
```

## 覆盖范围

| 钩子 | 时机 | 扫描对象 |
| --- | --- | --- |
| `pre-commit` | `git commit` | 暂存区新增/修改的文件 |
| `pre-push` | `git push` | 本次推送的提交相对远端的差异；新分支扫描完整树 |

手动全量检查：

```bash
node .githooks/secret-scan.mjs --all
```

GitHub Actions（`.github/workflows/secret-scan.yml`）也会在 push / pull request 时跑一遍，
即使本地用 `--no-verify` 绕过，服务端仍会失败。

## 会拦截什么

- 路径：`.sign/`、`.local/`、`signing.local.profile.json5`、根 `build-profile.json5`、
  `local.properties`、`.env*`（`.env.example` 除外）、`.npmrc`、`.ohpmrc`、
  `*.p12` / `*.p7b` / `*.cer` / `*.csr` / `*.jks` / `*.keystore` / `*.key`、
  `id_rsa` 等私钥文件、`extra-ca.pem`。
- 内容：私钥块、AWS/GitHub/OpenAI/DeepSeek/Slack/Google 常见 token、长 Bearer token。

命中时只打印文件路径、行号和规则名，不回显密钥内容。

## 误报

先确认内容确实不是密钥。确需临时绕过：

```bash
git commit --no-verify
git push --no-verify
```

共享分支不建议绕过；优先把文件移出版本控制并加入 `.gitignore`。
