# 引擎裁剪

`../engine-ship-files.txt` 是随应用打包的官方引擎文件清单（路径相对 `node_modules`）。它由 sdk profile 的**插件表**反推得到，不是手工挑选，也不是单一包的 import 闭包。

## 为什么不用 import 闭包

早期版本只追 `@deepseek-ai/dsh-sdk-app` 的 import 图，结果漏掉了 `@deepseek-ai/dsh-base`：这个 profile bundle 是按名字解析的，不走 import。宿主侧 `--dump-config` 只剩 14 个插件，并报 `system-prompt`、`session-title-llm`、`hmr`、`tool-plugin-manager` 四个 patch 缺失——引擎能起，但能力残废。

## 现在的流程

1. `dump-full.sh`：在完整依赖树上跑 `dsh --profile sdk --dump-config`，得到 111 个插件（110 个包 + dsh 自身）；
2. `ship-from-dump.mjs`：以这些插件包为根，沿每个包 `package.json` 的 `dependencies` 递归求并集，然后按规则列文件——跳过 `.d.ts`、`.map`、`.ts`、文档、locale、测试、`prebuilds/` 与真实二进制（`.node`/`.so`/`.dll`/`.exe`），保留全部 `package.json`；
3. `grow-ship-list.sh`：反复「打包 → 解到临时目录 → 宿主 Node 跑 dump」，把报错里缺失的包加入根集合，直到 `--dump-config` 退出码 0、插件数 ≥ 100、无 `cannot resolve` / `patch: entry not found`。

当前结果：552 个包 / 15786 个文件 / 39.2 MB gzip，dump 出 111 个插件、stderr 为空。

## 校验

- `bash scripts/engine-prune/scan-binaries.sh`：按文件头判断，清单里没有 ELF/PE（`bin/` 下都是 JS 脚本）；
- `bash scripts/check-engine-dump.sh`：直接验证 **HAP 里那份归档**，而不是工作目录里的中间产物。

## 换版本时

升级 `@deepseek-ai/dsh` 后重跑 `dump-full.sh` → `grow-ship-list.sh`，再跑两个校验脚本。不要手工改清单；漏包的表现是 dump 告警或插件数量下降。
