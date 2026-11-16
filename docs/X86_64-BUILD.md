# 完整 x86_64 模拟器构建

模拟器使用 x86_64 OHOS ABI。需要重新编译 Node、Bash、toybox、归档工具、ripgrep 和引擎原生插件；仅修改 HAR 的 abiFilters 无法启动完整运行时。

## 本机环境

WSL 的 `/var/tmp/deepseek-harmony-native` 保存已校验的 Node 24.22.1 源码、OHOS Linux SDK、LLVM 22、libc++ 22 的 `__n1` 头文件和其他工具源码。x86 构建位于独立的 `/var/tmp/deepseek-harmony-x86`，不会覆盖原 arm64 二进制。

从 WSL 仓库目录执行：

```bash
bash scripts/build-x86-runtime.sh setup
bash scripts/build-x86-runtime.sh node
bash scripts/build-x86-runtime.sh tools
bash scripts/build-x86-runtime.sh bash
bash scripts/build-x86-runtime.sh addons
bash scripts/build-x86-runtime.sh rg
bash scripts/build-x86-runtime.sh pack
```

Node 中断后使用 `node-resume` 复用对象文件。可用 `JOBS=12` 控制并发。V8 的构建机辅助工具优先使用 `-O0`，强制内联不兼容时使用 `-O2`，这些辅助程序不随应用分发。模拟器调试运行库的 C++ 编译使用 `-O1`，保留完整功能；首次构建中已完成的对象复用原优化级别。

`pack` 输出 `entry/libs/x86_64`，并替换引擎归档及运行时摘要为本次 x86 构建。打包前应保存 arm64 版本的归档和清单；本次备份位于 `.test-build/arm64-resources`，原 arm64 工具位于 `.test-build/libs-arm64-hold`。

HAR 的 `native/iec/platform/ohos/har/build-profile.json5` 应使用 `abiFilters: ["x86_64"]`。入口为 `pages/Index`，不是 `pages/KbTest`。运行时从系统报告的 nativeLibraryPath 或当前 ABI 的 bundle 路径生成工具启动器。

Windows 打包：

```powershell
node scripts/build.mjs --deveco-home 'D:\D Program Files\DevEco Studio'
```

安装时必须显式指定模拟器 `hdc -t 127.0.0.1:5555`，避免操作真机。

## 新增装载器验证

```bash
bash native/iec/tests/elf_dl_x86/run.sh
```

覆盖 x86_64 的相对重定位、GOT/PLT、弱符号、宿主函数查找与构造函数。x86 装载器遇到未实现的重定位会明确失败；当前三个引擎插件没有 TLS 重定位。
