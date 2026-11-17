// exec/path_resolver.cpp — where a requested program is looked up.
//
// These two functions answer "what does this path mean on this host?":
// UnderFakeRoot rewrites the system bin prefixes of an absolute path into the
// fake root when the PATH capability says only the app sandbox is reachable;
// ResolveFilePath applies POSIX PATH search to a bare name. Both are declared
// in exec_route.h.
#include "exec_route.h"

#include "caps.h"
#include "constant.h"
#include "fs/resolver.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

bool IsExecutableFile(const std::string& path) {
    struct stat st;

    if (stat(path.c_str(), &st) != 0) return false;
    if (!S_ISREG(st.st_mode)) return false;

    // When the native chmod is unreliable, the fs shim's sidecar is the only
    // truthful source for the executable bit; if it exists it also wins over
    // the kernel's (unchanged) mode.
    mode_t mode = 0;
    if (Caps().chmod < 3 && ReadChmodMarker(path, &mode))
        return ModeAllowsExec(mode, st);

    return access(path.c_str(), X_OK) == 0;
}

std::string PathForRequest(const std::vector<std::string>& env) {
    for (const std::string& e : env)
        if (e.compare(0, 5, "PATH=") == 0) return e.substr(5);

    if (const char* own = getenv("PATH")) return own;

    std::string fallback;
    size_t n = confstr(_CS_PATH, nullptr, 0);
    if (n > 0) {
        fallback.resize(n);
        confstr(_CS_PATH, &fallback[0], n);
        if (fallback.back() == '\0') fallback.pop_back();
    }
    return fallback;
}

const char* const kSysBins[] = {
    "/bin/", "/usr/bin/", "/usr/local/bin/", "/sbin/", "/usr/sbin/",
    "/system/bin/", "/vendor/bin/", "/system/lib/", "/data/app/bin/",
};

bool StartsWithSystemBin(const std::string& path) {
    for (const char* dir : kSysBins) {
        const size_t n = strlen(dir);   // every entry ends with '/'
        // A PATH entry names the directory itself ("/bin"), while a program
        // path names something under it ("/bin/ls"). Both live in the fake
        // root, and the entry form is exactly what a PATH search passes here;
        // matching only the trailing-slash form made "mksh" search the real
        // /bin, which the sandbox does not allow.
        if (path.size() >= n - 1 &&
            path.compare(0, n - 1, dir, n - 1) == 0 &&
            (path.size() == n - 1 || path[n - 1] == '/')) {
            return true;
        }
    }
    return false;
}

struct MapSet {
    std::vector<std::string> to;
    std::vector<iec_map_t> maps;
};

// The fake-root mapping table: each system bin prefix maps to the same path
// under FAKE_SYSROOT. The strings live in `to`, which is not modified after the
// table is built, so the pointers in `maps` stay valid.
const MapSet& FakeRootMaps() {
    static const MapSet set = [] {
        MapSet s;
        const size_t n = sizeof(kSysBins) / sizeof(kSysBins[0]);
        s.to.reserve(n);
        s.maps.resize(n);
        for (size_t i = 0; i < n; i++) {
            s.to.emplace_back(std::string(FAKE_SYSROOT) + kSysBins[i]);
            s.maps[i].from = kSysBins[i];
            s.maps[i].to = s.to.back().c_str();
        }
        return s;
    }();
    return set;
}

// Resolve simulated symlinks (.IEC_SYMLINK markers) and apply the fake-root
// maps. A path that the resolver cannot resolve is returned unchanged so the
// caller can report the original name.
std::string ResolveSimulated(const std::string& path, const std::string& cwd) {
    iec_opts_t opts{};
    if (Caps().path == 0) {
        const MapSet& maps = FakeRootMaps();
        opts.maps = maps.maps.data();
        opts.nmaps = maps.maps.size();
    }
    opts.cwd = cwd.empty() ? nullptr : cwd.c_str();
    opts.max_links = 40;

    char out[4096];
    const int rc = iec_resolve_path(path.c_str(), &opts, out, sizeof out);
    return rc == 0 ? std::string(out) : path;
}

// The fs shim cannot create symbolic links in this sandbox, so it stores them as
// ordinary files named <link>.IEC_SYMLINK whose content is the target string. Reading
// one is the same operation as readlink(), just from that file.
bool ReadMarkerTarget(const std::string& marker, std::string* target) {
    struct stat st;
    if (lstat(marker.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    if (st.st_size <= 0 || st.st_size > 4095) return false;

    const int fd = open(marker.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;

    char buf[4096];
    const ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return false;
    target->assign(buf, static_cast<size_t>(n));
    return true;
}

// Collapses "//", "." and ".."; a path that ends up empty is the root.
std::string NormalizePath(const std::string& path) {
    std::vector<std::string> parts;

    for (size_t i = 0; i < path.size();) {
        while (i < path.size() && path[i] == '/') i++;
        size_t j = i;
        while (j < path.size() && path[j] != '/') j++;
        if (i < j) {
            const std::string part = path.substr(i, j - i);
            if (part == "..") {
                if (!parts.empty()) parts.pop_back();
            } else if (part != ".") {
                parts.push_back(part);
            }
        }
        i = j;
    }

    std::string out;
    for (const std::string& part : parts) out += "/" + part;
    return out.empty() ? std::string("/") : out;
}

// Finds the first link anywhere in `path`, real or marker, and returns the path with
// that link expanded and the rest of the way spliced on. False means there is none.
bool ResolveOneLink(const std::string& path, std::string* out) {
    std::vector<std::string> segments;
    for (size_t i = 0; i < path.size();) {
        while (i < path.size() && path[i] == '/') i++;
        size_t j = i;
        while (j < path.size() && path[j] != '/') j++;
        if (i < j) segments.push_back(path.substr(i, j - i));
        i = j;
    }

    std::string prefix;
    for (size_t k = 0; k < segments.size(); k++) {
        prefix = NormalizePath(prefix + "/" + segments[k]);

        std::string target;
        struct stat st;
        if (lstat(prefix.c_str(), &st) == 0 && S_ISLNK(st.st_mode)) {
            char buf[4096];
            const ssize_t n = readlink(prefix.c_str(), buf, sizeof buf - 1);
            if (n <= 0) return false;
            target.assign(buf, static_cast<size_t>(n));
        } else if (!ReadMarkerTarget(prefix + ".IEC_SYMLINK", &target)) {
            continue;    // not a link: the next component is the interesting one
        }

        std::string rest;
        for (size_t r = k + 1; r < segments.size(); r++) rest += "/" + segments[r];

        std::string base = target;
        if (base.empty() || base[0] != '/') {
            // A relative target is relative to the link's own directory.
            const size_t slash = prefix.rfind('/');
            base = (slash == std::string::npos ? std::string() : prefix.substr(0, slash)) +
                   "/" + base;
        }
        *out = NormalizePath(base + rest);
        return true;
    }
    return false;
}

}  // namespace

std::string ResolveLaunchPath(const std::string& path, const std::string& cwd) {
    // /proc entries are process state, not files a program can be started from; a
    // magic link there must not be chased.
    if (path.empty() || path.compare(0, 6, "/proc/") == 0) return path;

    std::string work;
    if (path[0] == '/') {
        work = path;
    } else {
        std::string base = cwd;
        if (base.empty()) {
            char buf[4096];
            if (getcwd(buf, sizeof buf) == nullptr) return path;
            base = buf;
        }
        work = base + (base.back() == '/' ? "" : "/") + path;
    }

    // The kernel's own limit, for the same reason: a pair of links naming each other
    // must not be able to keep the exec server busy.
    for (int hops = 0; hops < 40; hops++) {
        std::string next;
        if (!ResolveOneLink(work, &next) || next == work) break;
        work = next;
    }
    return work;
}

std::string UnderFakeRoot(const std::string& path) {
    if (Caps().path != 0) return path;
    if (path.empty() || path[0] != '/') return path;

    const std::string mapped =
        StartsWithSystemBin(path) ? std::string(FAKE_SYSROOT) + path : path;
    return ResolveSimulated(mapped, "");
}

std::string ResolveFilePath(const std::string& path, const std::vector<std::string>& env,
                            const std::string& cwd) {
    if (path.find('/') != std::string::npos) return path;

    const std::string dirs = PathForRequest(env);
    size_t start = 0;

    for (;;) {
        const size_t colon = dirs.find(':', start);
        const size_t end = colon == std::string::npos ? dirs.size() : colon;
        const std::string dir = dirs.substr(start, end - start);
        // The search runs in the root the program will be started in, which is the fake
        // one where only the sandbox is reachable, so an absolute entry means inside it.
        const std::string in_root = UnderFakeRoot(dir);
        const std::string candidate =
            in_root.empty() ? (cwd.empty() ? path : cwd + "/" + path) : in_root + "/" + path;

        const std::string resolved = ResolveSimulated(candidate, cwd);
        if (IsExecutableFile(resolved)) return resolved;
        if (colon == std::string::npos) break;
        start = colon + 1;
    }
    return std::string();
}

bool ReadChmodMarker(const std::string& path, mode_t* mode) {
    const std::string marker = path + ".IEC_CHMOD";
    const int fd = open(marker.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;

    char buf[16];
    const ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return false;

    buf[n] = '\0';
    char* end = nullptr;
    const unsigned long m = strtoul(buf, &end, 8);
    if (end == buf || m > 07777) return false;

    *mode = static_cast<mode_t>(m);
    return true;
}

bool ModeAllowsExec(mode_t mode, const struct stat& st) {
    if ((mode & 0111) == 0) return false;

    const uid_t uid = geteuid();
    if (uid == 0) return true;
    if (st.st_uid == uid) return (mode & S_IXUSR) != 0;
    if (st.st_gid == getegid()) return (mode & S_IXGRP) != 0;

    const int n = getgroups(0, nullptr);
    if (n > 0) {
        std::vector<gid_t> groups(static_cast<size_t>(n));
        if (getgroups(n, groups.data()) == n) {
            for (const gid_t g : groups)
                if (g == st.st_gid) return (mode & S_IXGRP) != 0;
        }
    }
    return (mode & S_IXOTH) != 0;
}

bool EmulatedExecutable(const std::string& path) {
    if (Caps().chmod >= 3) return false;

    mode_t mode = 0;
    if (!ReadChmodMarker(path, &mode)) return false;

    struct stat st;
    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    return ModeAllowsExec(mode, st);
}
