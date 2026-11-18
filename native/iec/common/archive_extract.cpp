// common/archive_extract.cpp — see archive_extract.h.
//
// 这段代码原来在 platform/ohos/har/src/main/cpp/napi_init.cpp 里，和
// UnpackResource() 挤在同一个匿名 namespace。抽出来时行为一条没改：
//   * libarchive 仍然运行期 dlopen（HAR 不直接链接它，避免 Hvigor 把 .so
//     当构建产物；设备上是 build_libarchive.sh 放进 HAR libs 的 shim 版）；
//   * read_open_memory + write_disk_new 的调用顺序、extract 选项、
//     ARCHIVE_WARN 只记日志 / 更低的返回码算失败，都与原来相同；
//   * 条目路径仍然过 SafeJoin() 的 ".." 检查；
//   * 日志仍然走 Logger，文案不变（设备 hilog 的 grep 关键词不变）。
#include "common/archive_extract.h"

#include <dlfcn.h>
#include <sys/types.h>

#include <cerrno>
#include <cstdint>
#include <mutex>
#include <string>

#include "common/safe_path.h"
#include "logger/logger.h"

namespace {

struct Archive;
struct ArchiveEntry;

constexpr int kArchiveOk = 0;
constexpr int kArchiveEof = 1;
constexpr int kArchiveWarn = -20;
constexpr int kExtractPerm = 0x0002;
constexpr int kExtractTime = 0x0004;
// Values from libarchive's archive.h. Older releases ignore option bits they do
// not know (archive_write_disk_set_options just stores the mask), so enabling
// these does not turn into a load failure on an older device library.
constexpr int kExtractSecureSymlinks = 0x0100;
constexpr int kExtractSecureNoDotDot = 0x0200;
constexpr int kExtractSecureNoAbsolutePaths = 0x0400;

struct ArchiveApi {
    void* handle = nullptr;

    Archive* (*read_new)() = nullptr;
    int (*read_support_filter_all)(Archive*) = nullptr;
    int (*read_support_format_all)(Archive*) = nullptr;
    int (*read_open_memory)(Archive*, const void*, size_t) = nullptr;
    int (*read_next_header)(Archive*, ArchiveEntry**) = nullptr;
    ssize_t (*read_data)(Archive*, void*, size_t) = nullptr;
    int (*read_free)(Archive*) = nullptr;

    Archive* (*write_disk_new)() = nullptr;
    int (*write_disk_set_options)(Archive*, int) = nullptr;
    int (*write_header)(Archive*, ArchiveEntry*) = nullptr;
    ssize_t (*write_data)(Archive*, const void*, size_t) = nullptr;
    int (*write_finish_entry)(Archive*) = nullptr;
    int (*write_free)(Archive*) = nullptr;

    const char* (*error_string)(Archive*) = nullptr;
    const char* (*entry_pathname)(ArchiveEntry*) = nullptr;
    void (*entry_set_pathname)(ArchiveEntry*, const char*) = nullptr;
    const char* (*entry_hardlink)(ArchiveEntry*) = nullptr;
    void (*entry_set_hardlink)(ArchiveEntry*, const char*) = nullptr;
    const char* (*entry_symlink)(ArchiveEntry*) = nullptr;
    int64_t (*entry_size)(ArchiveEntry*) = nullptr;
};

template <typename T>
bool LoadSym(void* handle, const char* name, T* out)
{
    *out = reinterpret_cast<T>(dlsym(handle, name));
    return *out != nullptr;
}

const ArchiveApi& GetArchiveApi()
{
    static ArchiveApi api;
    static std::once_flag once;

    std::call_once(once, [] {
        static const char* const candidates[] = {
            "libarchive.so.13",
            "libarchive.so",
            "/data/storage/el1/bundle/libs/arm64/libarchive.so.13",
            "/data/storage/el1/bundle/libs/arm64/libarchive.so",
            "/data/storage/el1/bundle/libs/x86_64/libarchive.so.13",
            "/data/storage/el1/bundle/libs/x86_64/libarchive.so",
        };
        for (const char* name : candidates) {
            api.handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
            if (api.handle) break;
        }
        if (!api.handle) {
            Logger::GetInstance()->LogE("[iec] cannot dlopen libarchive: %s",
                                        dlerror());
            return;
        }

        bool ok = true;
        ok &= LoadSym(api.handle, "archive_read_new", &api.read_new);
        ok &= LoadSym(api.handle, "archive_read_support_filter_all",
                      &api.read_support_filter_all);
        ok &= LoadSym(api.handle, "archive_read_support_format_all",
                      &api.read_support_format_all);
        ok &= LoadSym(api.handle, "archive_read_open_memory",
                      &api.read_open_memory);
        ok &= LoadSym(api.handle, "archive_read_next_header",
                      &api.read_next_header);
        ok &= LoadSym(api.handle, "archive_read_data", &api.read_data);
        ok &= LoadSym(api.handle, "archive_read_free", &api.read_free);
        ok &= LoadSym(api.handle, "archive_write_disk_new",
                      &api.write_disk_new);
        ok &= LoadSym(api.handle, "archive_write_disk_set_options",
                      &api.write_disk_set_options);
        ok &= LoadSym(api.handle, "archive_write_header", &api.write_header);
        ok &= LoadSym(api.handle, "archive_write_data", &api.write_data);
        ok &= LoadSym(api.handle, "archive_write_finish_entry",
                      &api.write_finish_entry);
        ok &= LoadSym(api.handle, "archive_write_free", &api.write_free);
        ok &= LoadSym(api.handle, "archive_error_string", &api.error_string);
        ok &= LoadSym(api.handle, "archive_entry_pathname",
                      &api.entry_pathname);
        ok &= LoadSym(api.handle, "archive_entry_set_pathname",
                      &api.entry_set_pathname);
        ok &= LoadSym(api.handle, "archive_entry_hardlink",
                      &api.entry_hardlink);
        ok &= LoadSym(api.handle, "archive_entry_set_hardlink",
                      &api.entry_set_hardlink);
        ok &= LoadSym(api.handle, "archive_entry_symlink", &api.entry_symlink);
        ok &= LoadSym(api.handle, "archive_entry_size", &api.entry_size);

        if (!ok) {
            Logger::GetInstance()->LogE(
                "[iec] libarchive is missing one or more entry points");
            dlclose(api.handle);
            api = ArchiveApi();
        }
    });

    return api;
}

// Extracts an archive through libarchive's write-disk path.
bool ExtractTar(const unsigned char* data, size_t size,
                const std::string& dest) {
    const ArchiveApi& api = GetArchiveApi();
    if (!api.handle) return false;

    Archive* a = api.read_new();
    Archive* ext = api.write_disk_new();
    if (!a || !ext) {
        if (a) api.read_free(a);
        if (ext) api.write_free(ext);
        return false;
    }

    api.read_support_filter_all(a);
    api.read_support_format_all(a);
    api.write_disk_set_options(
        ext, kExtractTime | kExtractPerm | kExtractSecureSymlinks |
                 kExtractSecureNoDotDot | kExtractSecureNoAbsolutePaths);

    if (api.read_open_memory(a, data, size) != kArchiveOk) {
        const char* err = api.error_string(a);
        Logger::GetInstance()->LogE("[iec] archive open: %s",
                                    err ? err : "(unknown)");
        api.read_free(a);
        api.write_free(ext);
        return false;
    }

    bool ok = true;
    ArchiveEntry* entry = nullptr;
    for (;;) {
        int r = api.read_next_header(a, &entry);
        if (r == kArchiveEof) break;
        if (r < kArchiveOk) {
            const char* err = api.error_string(a);
            Logger::GetInstance()->LogE("[iec] archive header: %s",
                                        err ? err : "(unknown)");
            ok = false;
            break;
        }

        const char* name = api.entry_pathname(entry);
        // set_pathname() frees the string `name` points at, so the original
        // member name has to be copied before the rewrite.
        const std::string member = name ? name : "";
        std::string path;
        if (!iec::SafeJoinUnder(dest, name, &path)) {
            Logger::GetInstance()->LogE("[iec] archive: unsafe path %s",
                                        name ? name : "(null)");
            ok = false;
            break;
        }
        api.entry_set_pathname(entry, path.c_str());

        // A hard link to an unsafe target is refused outright, not kept with
        // its original (escaping) value.
        const char* hardlink = api.entry_hardlink(entry);
        if (hardlink) {
            std::string target;
            if (!iec::SafeJoinUnder(dest, hardlink, &target)) {
                Logger::GetInstance()->LogE("[iec] archive: unsafe hardlink %s -> %s",
                                            member.c_str(), hardlink);
                ok = false;
                break;
            }
            api.entry_set_hardlink(entry, target.c_str());
        }

        // Symlinks are created through fs/shim.c as a marker. libarchive's
        // SECURE_SYMLINKS stops it from following a pre-existing link outside
        // the destination; this check additionally refuses an absolute or
        // escaping target written by the archive itself.
        const char* symlink = api.entry_symlink(entry);
        if (symlink && !iec::SafeSymlinkTarget(member.c_str(), symlink)) {
            Logger::GetInstance()->LogE("[iec] archive: unsafe symlink %s -> %s",
                                        member.c_str(), symlink);
            ok = false;
            break;
        }

        // libarchive's write-disk path calls symlink(); the shared object is
        // linked with fs/shim.c, so a link becomes a <name>.IEC_SYMLINK marker
        // without any special case here.
        r = api.write_header(ext, entry);
        if (r == kArchiveWarn) {
            const char* err = api.error_string(ext);
            Logger::GetInstance()->LogW("[iec] archive header warn: %s",
                                        err ? err : "(unknown)");
        } else if (r < kArchiveWarn) {
            const char* err = api.error_string(ext);
            Logger::GetInstance()->LogE("[iec] archive write header: %s",
                                        err ? err : "(unknown)");
            ok = false;
            break;
        }

        if (api.entry_size(entry) > 0) {
            char buf[64 * 1024];
            ssize_t n;
            while ((n = api.read_data(a, buf, sizeof buf)) > 0) {
                if (api.write_data(ext, buf, static_cast<size_t>(n)) < 0) {
                    const char* err = api.error_string(ext);
                    Logger::GetInstance()->LogE("[iec] archive write data: %s",
                                                err ? err : "(unknown)");
                    ok = false;
                    break;
                }
            }
            if (n < 0) {
                const char* err = api.error_string(a);
                Logger::GetInstance()->LogE("[iec] archive read data: %s",
                                            err ? err : "(unknown)");
                ok = false;
            }
            if (!ok) break;
        }

        r = api.write_finish_entry(ext);
        if (r == kArchiveWarn) {
            const char* err = api.error_string(ext);
            Logger::GetInstance()->LogW("[iec] archive finish warn: %s",
                                        err ? err : "(unknown)");
        } else if (r < kArchiveWarn) {
            const char* err = api.error_string(ext);
            Logger::GetInstance()->LogE("[iec] archive finish: %s",
                                        err ? err : "(unknown)");
            ok = false;
            break;
        }
    }

    api.read_free(a);
    api.write_free(ext);
    return ok;
}

}  // namespace

extern "C" int IecExtractTar(const void* data, size_t size, const char* dest) {
    if (!data || !dest || !*dest) return 1;
    return ExtractTar(static_cast<const unsigned char*>(data), size, dest) ? 0 : 1;
}
