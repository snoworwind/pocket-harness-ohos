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

## 设备端（HarmonyOS 沙箱）不要用这个开关

`core.hooksPath` 要求 git 能 `execve` 钩子脚本本身。设备上应用进程不能直接执行普通脚本，且 `#!/bin/sh` 解析不到解释器，结果是 `git hook run pre-commit` 返回 **127**、**每次 `git commit` 直接失败**（只剩 `--no-verify` 能提交）。所以设备上执行 `node scripts/install-hooks.mjs` 等于把提交锁死。

设备上的正确做法是绕过 `core.hooksPath`，在 `.git/hooks/` 放两个本地包装脚本（该目录不入库，绝对路径可按机器写）：

```sh
git config --unset core.hooksPath      # 确认 git config core.hooksPath 为空
```

`.git/hooks/pre-commit`（`pre-push` 同理，末参换成 `--pre-push`）：

```sh
#!<IEC_SYSROOT>/bin/sh
exec node .githooks/secret-scan.mjs --staged
```

- shebang 必须是 `$IEC_SYSROOT/bin/sh` 的**真实绝对路径**（如 `.../files/runtime-<ver>/bin/sh`），不能写 `#!/bin/sh`，也不能用 `/usr/bin/env`（设备上没有）。
- 钩子逻辑仍只有 `.githooks/secret-scan.mjs` 一份，包装脚本只做 `exec node`。
- 验证：`git hook run pre-commit` 退出码为 0；故意 `git add` 一个假的 `AKIA...` 文件应被拦下。

## 覆盖范围

| 钩子 | 时机 | 扫描对象 |
| --- | --- | --- |
| `pre-commit` | `git commit` | 暂存区新增/修改的文件 |
| `pre-push` | `git push` | 本次推送区间内每个提交新增/修改的文件 + 提交信息；密钥在中间提交加入、后续删除也会被拦下；新分支扫描推送范围内的每个提交（不只 tip 树） |

手动全量检查：

```bash
node .githooks/secret-scan.mjs --all       # 当前跟踪树
node .githooks/secret-scan.mjs --history   # 历史提交 + 提交信息（默认最近 200 个）
SECRET_SCAN_HISTORY_LIMIT=1000 node .githooks/secret-scan.mjs --history
```

GitHub Actions（`.github/workflows/secret-scan.yml`）也会在 push / pull request 时跑一遍，
即使本地用 `--no-verify` 绕过，服务端仍会失败。

## 会拦截什么

- 路径：`.sign/`、`.local/`、`signing.local.profile.json5`、根 `build-profile.json5`、
  `local.properties`、`.env*`（`.env.example` 除外）、`.npmrc`、`.ohpmrc`、
  `*.p12` / `*.p7b` / `*.cer` / `*.csr` / `*.jks` / `*.keystore` / `*.key`、
  `id_rsa` 等私钥文件、`extra-ca.pem`。
- 内容：PEM 私钥块（含 ENCRYPTED）、AWS/GitHub/GitLab/OpenAI（含 `sk-proj-`）/DeepSeek/Slack/Google/Stripe/npm/HuggingFace/SendGrid token、华为云 AK/SK、阿里云 AccessKey、腾讯云 SecretId、长 Bearer token。

命中时只打印文件路径、行号和规则名，不回显密钥内容。

## 误报

先确认内容确实不是密钥。确需临时绕过：

```bash
git commit --no-verify
git push --no-verify
```

共享分支不建议绕过；优先把文件移出版本控制并加入 `.gitignore`。
