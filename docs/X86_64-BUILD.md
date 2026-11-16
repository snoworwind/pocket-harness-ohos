# 完整 x86_64 模拟器构建

模拟器使用 x86_64 OHOS ABI。需要重新编译 Node、Bash、toybox、归档工具、ripgrep 和引擎原生插件；仅修改 HAR 的 `abiFilters` 无法启动完整运行时。

## 构建根

`scripts/build-x86-runtime.sh` 使用两个目录：

- `NATIVE_BASE`（默认 `/var/tmp/deepseek-harmony-native`）：已校验的 Node 24.22.1 源码、OHOS Linux SDK、LLVM 22、libc++ 22 的 `__n1` 头文件和其他工具源码；
- `X86_ROOT`（默认 `/var/tmp/deepseek-harmony-x86`）：独立的 x86 构建树，不会覆盖 arm64 产物。

两者都可以用环境变量覆盖，目录里需要有可用的 OHOS SDK 与已下载的 Node 源码包。

## 构建

在 WSL 的仓库根目录执行：

```bash
bash scripts/build-x86-runtime.sh setup
bash scripts/build-x86-runtime.sh node
bash scripts/build-x86-runtime.sh tools
bash scripts/build-x86-runtime.sh bash
bash scripts/build-x86-runtime.sh addons
bash scripts/build-x86-runtime.sh rg
bash scripts/build-x86-runtime.sh pack
```

- `scripts/patch-v8-drumbrake.sh` 是实验性的：Node 24.22.1 随包的 DrumBrake 源码落后于同版本 V8 API，打开后无法编译，因此默认不启用；无 JIT 下的 fetch 由 `harmony/fetch-polyfill.cjs` 提供。
- Node 中断后用 `node-resume` 复用对象文件；`JOBS` 控制并发（建议不超过 12，16 以上容易触发 OOM）。
- V8 的构建机辅助工具优先 `-O0`，强制内联不兼容时用 `-O2`；这些辅助程序不随应用分发。
- `pack` 会改写 `entry/libs/x86_64`、引擎归档和 `runtime-manifest.json`。切换架构前请自行备份 arm64 的 `entry/libs/arm64-v8a`、引擎归档与清单（或从版本库重新生成），切回 arm64 时按 README 的流程恢复。

HAR 的 `native/iec/platform/ohos/har/build-profile.json5` 应使用 `abiFilters: ["x86_64"]`；arm64 默认值是 `["arm64-v8a"]`。运行时从系统报告的 `nativeLibraryPath` 或当前 ABI 的 bundle 路径生成工具启动器。

Windows 打包：

```powershell
node scripts/build.mjs --deveco-home "<DevEco 安装目录>"
```

安装时必须显式指定模拟器 `hdc -t 127.0.0.1:5555`，避免操作真机。

## 新增装载器验证

```bash
bash native/iec/tests/elf_dl_x86/run.sh
```

覆盖 x86_64 的相对重定位、GOT/PLT、弱符号、宿主函数查找与构造函数。x86 装载器遇到未实现的重定位会明确失败；当前引擎插件没有 TLS 重定位。
