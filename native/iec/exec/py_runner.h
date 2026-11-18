// py_runner.h — 独立 python 解释器进程的启动入口。
#pragma once

#ifdef __cplusplus
#include <cstdint>
extern "C" {
#else
#include <stdbool.h>
#include <stdint.h>
#endif

// 协议侧资源上限。客户端同一时刻最多这么多个请求（handler 进程数）；每个
// 请求的参数、环境条目数、单条字符串、内联 stdin 与客户端收到的输出总量都
// 有上限，超限在读取阶段直接拒绝，不把 runner 撑到 OOM。
// 文件路径形态的 stdin 仍然边读边喂管道，不占 runner 内存，但文件本身有
// 64 MiB 上限，避免请求无限长。
#define IEC_PY_MAX_ARGS 256u
#define IEC_PY_MAX_ENV 256u
#define IEC_PY_MAX_STRING (64u * 1024u)
#define IEC_PY_MAX_INLINE_STDIN (16u * 1024u * 1024u)
#define IEC_PY_MAX_STDIN_FILE (64u * 1024u * 1024u)
#define IEC_PY_MAX_CLIENT_OUTPUT (64u * 1024u * 1024u)
#define IEC_PY_MAX_CLIENTS 16u

static inline bool IecPyRequestLimitsOk(uint32_t argc, uint32_t envc,
                                        uint32_t stdin_len) {
    if (argc == 0 || argc > IEC_PY_MAX_ARGS || envc > IEC_PY_MAX_ENV) return false;
    if (stdin_len != 0xffffffffu && stdin_len > IEC_PY_MAX_INLINE_STDIN)
        return false;
    return true;
}

// 幂等。返回 false 表示 socket 建不起来（调用方只记日志，不影响其它工具）。
bool StartPyRunner();

#ifdef __cplusplus
}  // extern "C"
#endif
