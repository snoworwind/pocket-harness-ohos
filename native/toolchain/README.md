# 交叉编译环境

目标：`aarch64-linux-ohos` 的共享库，能在鸿蒙应用里由 IEC 的原生子进程装载。

这些脚本是从实际构建过程里沉淀下来的，路径默认写死在 `/var/tmp/deepseek-harmony-native`（下文 `$ROOT`）。换机器先改路径。

## 组成

| 组件 | 来源 | 用途 |
| --- | --- | --- |
| OHOS clang 15 工具链 | 华为 `repo.huaweicloud.com` 预编译包 | 一般工具（bash、toybox、libarchive）与 `sysroot` |
| OHOS NDK sysroot（API 24） | DevEco Studio `sdk/default/openharmony/native/sysroot` | 目标系统头文件与库 |
| SDK `libc++_shared.so` | 同上 `llvm/lib/aarch64-linux-ohos` | 设备上的 C++ 运行库（只导出 `std::__n1`） |
| **SDK `libcxx-ohos` 头文件** | 同上 `llvm/include/libcxx-ohos/include/c++/v1` | **唯一与上面运行库 ABI 匹配的一套**（`_LIBCPP_ABI_NAMESPACE __n1`） |
| LLVM 22 驱动与内建头 | `clang-22`、`libclang-common-22-dev` 等 deb | V8 需要 C++20 与较新的内建头 |

## 为什么混用两套编译器

Node 24 的 V8 使用 `std::ranges::lower_bound` + `std::views::iota` 等 C++20 设施，NDK 自带的 libc++ 15 完全没有这些，用 clang 15 直接编译会在 `transitions-inl.h`、`descriptor-array-inl.h` 处失败。

做法是：**用 LLVM 22 的驱动和内建头 + SDK 的 libcxx-ohos 头文件，链接 OHOS sysroot 与 SDK 的 `libc++_shared.so`**。

### 关键：ABI 命名空间必须对齐

`libc++` 的符号落在内联命名空间里，这个命名空间由头文件的 `__config_site` 决定：

```
llvm22/usr/include/c++/v1                      -> _LIBCPP_ABI_NAMESPACE __1
ndk-cxx/include/c++/v1                         -> _LIBCPP_ABI_NAMESPACE __1
<sdk>/llvm/include/c++/v1                      -> _LIBCPP_ABI_NAMESPACE __1
<sdk>/llvm/include/libcxx-ohos/include/c++/v1   -> _LIBCPP_ABI_NAMESPACE __n1   ← 与运行库一致，但没有 <ranges>
```

随 HAP 打包的 `libc++_shared.so` 只导出 `std::__n1`（`nm -D --defined-only` 里 1055 个 `_ZNSt4__n1…`，0 个 `_ZNSt3__1…`）。而 V8 需要 `std::ranges` / `std::views`，只有 libc++ 22 的头文件才有。

所以现在的组合是：**libc++ 22 的完整头文件 + 把 `__config_site` 的 `_LIBCPP_ABI_NAMESPACE` 改成 `__n1`**。`build-node24.sh` 会把它复制到 `$ROOT/libcxx22-n1/include/c++/v1` 并改这一行，wrapper 用 `-nostdinc++ -isystem` 指过去。

两种错配都会在真机上炸：

- 用 `__1` 头文件（llvm22/ndk-cxx 默认）：`dlopen libnode.so` 报 `_ZNSt3__119__shared_weak_count14__release_weakEv: symbol not found`；
- 用 SDK 的 `libcxx-ohos`（`__n1` 但旧）：V8 的 `std::ranges::lower_bound`、`std::views::iota` 编不过。

验证脚本：`scripts/probe-ranges-n1.sh`（编一个用 ranges 的 probe，`-z defs` 链接随包 `libc++_shared.so`，验证符号全解析）、`scripts/check-libcxx-abi.sh`（核对各产物引用的命名空间）。改头文件后必须删 `out/Release` 全量重编。

## 其他补齐

1. `-D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE`，否则 libc++ 在 OHOS 的 musl 风格 ctype 上会 `unknown rune table`；
2. 上游 clang 驱动会找 `crtbeginS.o` / `crtendS.o` 与 `libclang_rt.builtins.a`，OHOS 工具链只带 `clang_rt.crtbegin.o` 形式，需要把 `$ROOT/llvm22/usr/lib/clang/22/lib/aarch64-linux-ohos` 指向 SDK 的库目录，并补两个别名符号链接。

## 脚本

- `build-node24.sh`：准备 `libcxx-n1` 头文件与 wrapper、修 Node 版本与补丁、启动 `build_node.sh all`；
- `build-addons.sh`：用同一个 wrapper 编 `require_builtin.node`、`system.node`、`pty.node`；
- `fix-node-toolchain.sh`：只重写 compiler wrapper（调试用）；
- `fix-crt-libs.sh` / `fix-crt-aliases.sh`：补 CRT 搜索路径与 `crtbeginS/crtendS` 别名；
- `fix-pcre2.sh`：补 `oh-uni-package.json`（CMake 工具链要读它），否则 pcre2 配置失败。

## 已知限制

- `libnode.so` 依赖随 HAP 一起装的 `libc++_shared.so`；升级 DevEco SDK 后必须重新核对 `__config_site` 的命名空间（`scripts/check-libcxx-abi.sh`），不匹配就重新编译。
- `libarchive.so.13` 是 C 库，只依赖 `libc.so`；它由 `archive_extract.cpp` 在运行期 `dlopen`，必须随 HAP 进 `libs/arm64-v8a/`。
- V8 以 JIT-less 方式启动（`IEC_NODE_JITLESS=on`），性能与兼容性需要真机测量。
