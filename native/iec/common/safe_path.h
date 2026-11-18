// common/safe_path.h — archive member and link target checks.
//
// Kept header-only and free of libarchive so the host self-test can pin the
// decisions without loading the archive library.
#pragma once

#include <cstddef>
#include <string>

namespace iec {

// A member name may not escape the destination directory: no absolute path and
// no ".." component. Returns dest + "/" + name on success.
inline bool SafeJoinUnder(const std::string& dest, const char* name, std::string* out) {
    if (!name || !*name) return false;

    std::string rel(name);
    while (!rel.empty() && rel.front() == '/') rel.erase(rel.begin());
    if (rel.empty()) return false;

    for (size_t pos = 0; (pos = rel.find("..", pos)) != std::string::npos;) {
        const bool left = pos == 0 || rel[pos - 1] == '/';
        const bool right = pos + 2 == rel.size() || rel[pos + 2] == '/';
        if (left && right) return false;
        pos += 2;
    }

    *out = dest + "/" + rel;
    return true;
}

// A symlink target must stay inside the extraction root once it is resolved
// against the directory the link itself lives in. Absolute targets are always
// refused; a relative ".." is allowed only while it does not climb above the
// root (the Python stdlib archive legitimately contains lib/python3.12 ->
// ../python/lib/python3.12).
inline bool SafeSymlinkTarget(const char* link_name, const char* target) {
    if (!link_name || !*link_name || !target || !*target) return false;
    if (target[0] == '/') return false;

    int depth = 0;
    const std::string link(link_name);
    const size_t slash = link.find_last_of('/');
    const std::string dir = slash == std::string::npos ? std::string() : link.substr(0, slash);
    for (size_t i = 0; i < dir.size();) {
        while (i < dir.size() && dir[i] == '/') i++;
        size_t j = i;
        while (j < dir.size() && dir[j] != '/') j++;
        if (i < j) {
            const std::string part = dir.substr(i, j - i);
            if (part == "..") {
                if (depth == 0) return false;
                depth--;
            } else if (part != ".") {
                depth++;
            }
        }
        i = j;
    }

    for (size_t i = 0; target[i] != '\0';) {
        while (target[i] == '/') i++;
        size_t j = i;
        while (target[j] != '\0' && target[j] != '/') j++;
        if (i < j) {
            const std::string part(target + i, j - i);
            if (part == "..") {
                if (depth == 0) return false;
                depth--;
            } else if (part != ".") {
                depth++;
            }
        }
        i = j;
    }
    return true;
}

}  // namespace iec
