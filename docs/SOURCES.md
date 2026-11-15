# 随包组件的来源

规则：**HAP 里的二进制要么来自华为官方 SDK，要么来自 DeepSeek 官方发布物，要么在本机从源码编译。** 没有第三种来源，也没有把第三方预编译二进制塞进包里。

核对方式：`bash scripts/audit-sources.sh`。它解包 HAP，列出全部二进制，和预期集合比对，检查引擎归档里的原生插件，并把 `npm.tar.gz` 与本次 Node 构建的产物做逐字节比较。

## 二进制

| 包里文件 | 上游源码 | 本机怎么来的 | 许可 |
| --- | --- | --- | --- |
| `libnode.so` | Node.js v24.22.1 源代码包（nodejs.org，SHA-256 校验） | `native/toolchain/build-node24.sh` → `build_node.sh`，OHOS sysroot + LLVM 22 驱动编译，`llvm-strip --strip-unneeded` | MIT |
| `libbash.so` | GNU Bash 5.3（ftp.gnu.org） | `native/build-bash.sh`，`--host=aarch64-linux-ohos` | GPL-3.0 |
| `libtoybox.so` | toybox 0.8.14 | `native/iec/scripts/build_toybox.sh` | BSD |
| `libbsdtar.so`、`libbsdcpio.so`、`libbsdunzip.so`、`libzipcmd.so` | libarchive 3.7.7 | `native/iec/scripts/build_libarchive.sh` | BSD-2-Clause |
| `libarchive.so.13` | libarchive 3.7.7 | 同上脚本的 `--enable-shared` 产物（链 `fs/shim.c`，只依赖 `libc.so`）；`scripts/pack-native.sh` 复制进 `entry/libs`，供 `archive_extract.cpp` 在运行期 `dlopen` 解包引擎与 npm | BSD-2-Clause |
| `libiec_server.so`、`libncploader.so` | `native/iec` 源码（Bettersh/Guncat，随仓库） | hvigor 的 `externalNativeOptions` 用 DevEco NDK 现场编译 | 见 `native/BETTERSH-LICENSE`、`native/GUNCAT-LICENSE` |
| `libc++_shared.so` | DevEco Studio SDK（华为官方） | hvigor 从 SDK 拷贝 | LLVM Apache-2.0-with-LLVM-exception |
| `require_builtin.node` | `github.com/deepseek-ai/dsh-node-addon-require-builtin`（DeepSeek 官方，master 分支源码） | `native/toolchain/build-addons.sh`，NAPI_VERSION=9 | MIT |
| `system.node` | `@deepseek-ai/node-addon-system` 包内 `src/flock.c`（DeepSeek 官方） | 同上脚本编译 | BSD-3-Clause |
| `pty.node` | node-pty 1.2.0-beta.15 源码里的 `src/unix/pty.cc`（微软，MIT） | `native/toolchain/build-addons.sh` 用 OHOS 工具链 + node-addon-api 编译成 NAPI 插件，加载路径为 `node-pty/build/Release/pty.node` | MIT |
| `librg.so` | ripgrep 14.1.1 源码（crates.io） | `scripts/rg/build-ripgrep.sh`，cargo 目标 `aarch64-unknown-linux-ohos`，编译成导出 `iec_rg_main` 的 cdylib，`llvm-strip` 后 4.9 MB | Unlicense OR MIT |

## 数据归档

| 包里文件 | 来源 | 说明 |
| --- | --- | --- |
| `official-engine.tar.gz` | `npm install @deepseek-ai/dsh@0.2.2-rc.1`（DeepSeek 官方发布物） | 只删 `.d.ts`、`.map`、`.ts` 源码、`.md`、`.pdb` 与外部平台 `prebuilds/`，其余保留（闭包 572 个包 / 25,606 个文件 / 43.8 MB gzip）；再叠加上面三个本机编译的插件。用于 sdk 与 web 两个 profile（111 / 291 个插件），见 `scripts/check-engine-dump.sh`、`scripts/check-engine-web.sh`、`scripts/engine-prune/finalize-ship-list.sh` |
| `npm.tar.gz` | Node.js v24.22.1 源码树里的 `deps/npm`（npm 11.19.1） | `build_node.sh` 打包；`pack-native.sh` 覆盖仓库里的旧副本，审计脚本校验与构建产物一致 |
| `node_modules/@vscode/ripgrep` | 本工程自写的兼容包（MIT） | 上游包只做「找到 rg 路径」这一件事，且会 require 平台预编译包；这里换成把 `rgPath` 指向 `<sysroot>/bin/rg` 的 8 行模块 |
| `assets/cacert.pem` | Mozilla CA 根证书集 | 纯数据，编译进 `libiec_server.so` |

## 构建工具（不随包分发）

这些只在本机用来编译，不进入 HAP：

- OpenHarmony clang 15 工具链与 sysroot（华为官方，`repo.huaweicloud.com` 与 DevEco SDK）；
- LLVM 22 驱动、libc++ 22 头文件（Ubuntu 26.04 的 `clang-22`、`libc++-22-dev` 等包）；
- 宿主机 GCC 15、CMake、Ninja、Python、Node（只在 WSL 里跑脚本）。

关于 libc++：编译 `libnode.so` 与三个 `.node` 插件用的是 **libc++ 22 的头文件，并把 `_LIBCPP_ABI_NAMESPACE` 设为 `__n1`**（V8 需要 `<ranges>`；随包的 `libc++_shared.so` 只导出 `std::__n1` 符号）。头文件与运行库的命名空间必须一致：用默认 `__1` 头文件编出来的产物，在真机上 `dlopen` 会报 `_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found`。没有链接任何非官方 libc++ 库文件。

## 已知未纳入的组件

- 其余第三方原生库没有随包；后续新增组件同样必须从源码编译，并同步更新本表与 `scripts/audit-sources.sh`。
