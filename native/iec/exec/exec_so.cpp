


// exec/exec_so.cpp — the launcher for a shared object.
//
// A launcher is four or five lines of text:
//
//   #IECSOv2
//   /absolute/path/to/libfoo.so
//   entry_symbol
//   2                       -- 2 for (argc, argv), 3 for (argc, argv, envp)
//   0                       -- primary launch kind, 0 for auto
//
// It exists for the case where execve is not how programs are started but loading one
// still is: the file names what to load and where to jump. The reading and parsing
// happen in the parent (see Spawn() in exec_server.cpp), where allocating is safe; the
// loading and the call happen in the forked child, in SpawnSo() below.
#include "exec_so.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>

#define IEC_SO_MAGIC "#IECSOv2"

// A launcher can also sit next to the file it starts. That is what lets one command be
// a real ELF executable -- so a Go program's own fork/execve can run it -- while the
// server keeps starting it through the .so it names. The sidecar uses the same five
// lines and this suffix.
#define IEC_SO_SIDECAR ".iecso"

bool HasMagic(const std::string& path) {
    char magic[sizeof IEC_SO_MAGIC - 1];
    struct stat st;
    ssize_t n;
    int fd;

    // One open() with the checks in its flags instead of stat() then open(): a
    // FIFO swapped in between the two used to block the single-threaded exec
    // service. O_NOFOLLOW refuses a link, O_NONBLOCK makes a non-regular file
    // fail instead of waiting on it, and fstat() is what actually proves the
    // opened object is a regular file.
    fd = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return false;
    }
    n = read(fd, magic, sizeof magic);
    close(fd);
    return n == (ssize_t)sizeof magic && memcmp(magic, IEC_SO_MAGIC, sizeof magic) == 0;
}

bool IsSoLauncher(const std::string& path) {
    return HasMagic(path) || HasMagic(path + IEC_SO_SIDECAR);
}

bool HasSoSidecar(const std::string& path) {
    struct stat st;
    return stat((path + IEC_SO_SIDECAR).c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

namespace {

// Reads and parses one launcher file. Keeping this separate is what makes the sidecar
// fallback below a fallback rather than second full parser.
bool ParseLauncher(const std::string& path, SoLauncher& out, std::string* err) {
    // The reason travels in one place, so a caller that does not want it can pass null.
    auto fail = [err](const std::string& why) {
        if (err) *err = why;
        return false;
    };

    char buf[4096 + 1];
    struct stat st;
    int fd;
    ssize_t n;

    // Same TOCTOU fix as HasMagic: open once with the flags, then fstat the
    // descriptor that will actually be read.
    fd = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return fail(std::string("open failed: ") + strerror(errno));
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return fail("not a regular file");
    }
    n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return fail("the file is empty");
    buf[n] = '\0';

    // Five lines, in order: the magic, the object, the entry, the arity, and an
    // optional number naming the process relationship (0 = let the server decide,
    // 1 = fork, 2 = native child process, 3 = in this process). The fifth line may be
    // absent, which is the same as 0; anything past it is ignored.
    std::string lines[5];
    int li = 0;
    const char* p = buf;
    while (li < 5 && p && *p) {
        const char* e = strchr(p, '\n');
        std::string l = e ? std::string(p, (size_t)(e - p)) : std::string(p);
        while (!l.empty() && (l.back() == '\r' || l.back() == ' ' || l.back() == '\t'))
            l.pop_back();
        lines[li++] = l;
        p = e ? e + 1 : nullptr;
    }
    if (li < 4) {
        char m[96];
        snprintf(m, sizeof m, "expected at least 4 lines, but got %d", li);
        return fail(m);
    }
    if (lines[0] != IEC_SO_MAGIC) return fail("the first line is not " IEC_SO_MAGIC);
    if (lines[1].empty() || lines[1][0] != '/')
        return fail("the second line is not an absolute path");
    if (lines[2].empty()) return fail("the third line is empty");
    if (lines[2].size() > 255) return fail("the third line is too long");
    if (lines[3] != "2" && lines[3] != "3") return fail("the fourth line is neither 2 nor 3");

    out.so = lines[1];
    out.entry = lines[2];
    out.arity = (lines[3] == "3") ? 3 : 2;
    out.primary = PrimaryLaunchKind::kAuto;
    if (li >= 5 && !lines[4].empty()) {
        if (lines[4].size() != 1 || lines[4][0] < '0' || lines[4][0] > '3') {
            return fail("the fifth line is not one of 0, 1, 2, 3");
        }
        out.primary = static_cast<PrimaryLaunchKind>(lines[4][0] - '0');
    }
    return true;
}

}  // namespace

bool ResolveSoLauncher(const std::string& path, SoLauncher& out, std::string* err) {
    if (ParseLauncher(path, out, err)) return true;
    return ParseLauncher(path + IEC_SO_SIDECAR, out, err);
}

// What the child leaves with when the object will not load, and when it loads but the
// entry point is not in it. Neither is a status the program itself produced, so both
// stay clear of everything a program can return and of 127, which a shell reads as
// "command not found".
constexpr int kSoLoadFailedExit = 125;
constexpr int kSoEntryMissingExit = 126;

pid_t SpawnSo(const SpawnRequest& req) {
    std::vector<char*> argv;
    std::vector<char*> envp;
    int argc;
    int rc;

    // The entry point is called the way a program's main() is, so it gets the counts a
    // program started by the kernel would get: the number of arguments without the
    // terminating null that argv carries, and the environment as the array it is (envp
    // is terminated the same way, for the shape that asks for it).
    argv.reserve(req.argv.size() + 1);
    envp.reserve(req.env.size() + 1);
    for (const std::string& s : req.argv) argv.push_back(const_cast<char*>(s.c_str()));
    for (const std::string& s : req.env)  envp.push_back(const_cast<char*>(s.c_str()));
    argc = (int)argv.size();
    argv.push_back(nullptr);
    envp.push_back(nullptr);

    if (!req.cwd.empty() && chdir(req.cwd.c_str()) != 0) {
        static const char msg[] = "[exec] chdir failed, started in default path\n";
        if (write(STDERR_FILENO, msg, sizeof msg - 1)) {}
    }

    // Reading the launcher is part of starting it, so it happens here and not in the
    // caller: one function is the whole of this route, and what it fails with is the
    // same kind of thing as a load that fails -- the caller hears about it in the exit
    // status, not in the reply to its request. Allocating in this child is what the
    // loading below does anyway, the loader's locks and all.
    SoLauncher launcher;
    std::string err;
    if (!ResolveSoLauncher(req.path, launcher, &err)) {
        // The status alone cannot tell a malformed launcher from a missing object,
        // and both are mistakes made by whoever wrote the launcher. Say which one.
        const std::string msg = "[exec] bad launcher " + req.path + ": " + err + "\n";
        if (write(STDERR_FILENO, msg.data(), msg.size())) {}
        _exit(kSoLoadFailedExit);
    }


    void* h = dlopen(launcher.so.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char* why = dlerror();
        const std::string msg = "[exec] dlopen " + launcher.so + ": " +
                                (why ? why : "unknown error") + "\n";
        if (write(STDERR_FILENO, msg.data(), msg.size())) {}
        _exit(kSoLoadFailedExit);
    }

    auto missing_entry = [&]() {
        const char* why = dlerror();
        const std::string msg = "[exec] dlsym " + launcher.entry + " in " +
                                launcher.so + ": " + (why ? why : "not found") + "\n";
        if (write(STDERR_FILENO, msg.data(), msg.size())) {}
        _exit(kSoEntryMissingExit);
    };

    using EntryFn2 = int (*)(int, char**);
    using EntryFn3 = int (*)(int, char**, char**);
    if (launcher.arity == 3) {
        auto fn3 = (EntryFn3)dlsym(h, launcher.entry.c_str());
        if (!fn3) missing_entry();
        rc = fn3(argc, argv.data(), envp.data());
    } else {
        auto fn = (EntryFn2)dlsym(h, launcher.entry.c_str());
        if (!fn) missing_entry();
        rc = fn(argc, argv.data());
    }

    // The program's buffered output still has to go somewhere, and the _exit() below
    // would throw it away. This does mean touching stdio in the child of a fork, which
    // the server otherwise keeps out of there; it is accepted for the same reason the
    // loader call above is, since the alternative is a program whose output vanishes.
    fflush(nullptr);
    _exit(rc & 0xFF);
    return -1;  // not reached: every path above leaves through _exit()
}