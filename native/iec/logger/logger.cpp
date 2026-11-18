// logger/logger.cpp — see logger/logger.h.
#include "logger/logger.h"

#include "common/constant.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <utility>
#include <sys/stat.h>
#include <unistd.h>

namespace {

// Rotation: one file per process, at most this many bytes before it becomes
// <name>.1; the previous .1 becomes .2 and the oldest is dropped. Two rotated
// files bound one service's log to 3 * 4 MiB even if it runs for days.
constexpr off_t kMaxFileBytes = 4 * 1024 * 1024;
constexpr int kMaxRotations = 2;

char LevelTag(int level) {
    if (level >= 3) return 'D';
    if (level >= 2) return 'E';
    if (level == 1) return 'W';
    return 'I';
}

char Lower(char c) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
}

bool StartsWithIgnoreCase(const std::string& text, size_t pos, const char* word) {
    for (size_t i = 0; word[i] != '\0'; i++) {
        if (pos + i >= text.size() || Lower(text[pos + i]) != Lower(word[i]))
            return false;
    }
    return true;
}

bool IsSensitiveKey(const std::string& key) {
    std::string k;
    k.reserve(key.size());
    for (char c : key) k.push_back(Lower(c));

    if (k == "authorization" || k == "proxy-authorization" || k == "cookie" ||
        k == "set-cookie" || k == "password" || k == "passwd" ||
        k == "secret" || k == "token" || k == "api_key" || k == "apikey" ||
        k == "access_token" || k == "refresh_token" || k == "private_key") {
        return true;
    }

    auto ends_with = [&k](const char* suffix) {
        const size_t n = std::strlen(suffix);
        return k.size() >= n && k.compare(k.size() - n, n, suffix) == 0;
    };
    return ends_with("_key") || ends_with("-key") || ends_with("_token") ||
           ends_with("-token") || ends_with("_secret") || ends_with("_password");
}

// Header-style keys whose value may contain spaces ("Bearer ..."), so the mask
// has to run to the end of the line rather than to the first space.
bool IsWholeLineKey(const std::string& key) {
    std::string k;
    k.reserve(key.size());
    for (char c : key) k.push_back(Lower(c));
    return k == "authorization" || k == "proxy-authorization" ||
           k == "cookie" || k == "set-cookie";
}

bool IsValueDelimiter(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '&' ||
           c == ';' || c == ',' || c == '"' || c == '\'';
}

}  // namespace

std::string Logger::Redact(const std::string& text) {
    std::string out;
    out.reserve(text.size());

    for (size_t i = 0; i < text.size();) {
        // "KEY=VALUE", "KEY: VALUE", "--password=...", "?token=...": the key
        // is the identifier immediately before the separator.
        if (text[i] == '=' || text[i] == ':') {
            size_t key_start = i;
            while (key_start > 0) {
                const char c = text[key_start - 1];
                if (std::isalnum(static_cast<unsigned char>(c)) || c == '_' ||
                    c == '-' || c == '.') {
                    key_start--;
                } else {
                    break;
                }
            }
            const std::string key = text.substr(key_start, i - key_start);
            out.push_back(text[i]);
            if (IsSensitiveKey(key)) {
                size_t value = i + 1;
                while (value < text.size() &&
                       (text[value] == ' ' || text[value] == '\t')) {
                    out.push_back(text[value]);
                    value++;
                }
                if (IsWholeLineKey(key)) {
                    while (value < text.size() && text[value] != '\r' &&
                           text[value] != '\n') {
                        value++;
                    }
                } else {
                    while (value < text.size() && !IsValueDelimiter(text[value])) value++;
                }
                out.append("***");
                i = value;
                continue;
            }
            i++;
            continue;
        }

        // A bare "Bearer <token>" outside an Authorization header.
        if (StartsWithIgnoreCase(text, i, "bearer") &&
            (i == 0 || !std::isalnum(static_cast<unsigned char>(text[i - 1])))) {
            out.append(text, i, 6);
            size_t value = i + 6;
            while (value < text.size() &&
                   (text[value] == ' ' || text[value] == '\t')) {
                out.push_back(text[value]);
                value++;
            }
            if (value < text.size() && !IsValueDelimiter(text[value])) {
                while (value < text.size() && !IsValueDelimiter(text[value])) value++;
                out.append("***");
                i = value;
                continue;
            }
            i = value;
            continue;
        }

        out.push_back(text[i]);
        i++;
    }
    return out;
}

// The directory comes from the compile-time IEC_LOG_DIR when the platform
// defines it, otherwise from $IEC_LOG_DIR or $HOME/logs. The file name is
// assembled at runtime from the pid and a timestamp.
std::string LogDirectory() {
#ifdef IEC_LOG_DIR
    return IEC_LOG_DIR;
#else
    const char* dir = getenv("IEC_LOG_DIR");
    if (dir && *dir) return dir;
    const char* home = getenv("HOME");
    if (home && *home) return std::string(home) + "/logs";
    return std::string();
#endif
}

std::string DefaultLogPath() {
    std::string base = LogDirectory();
    if (base.empty()) return std::string();
    while (base.size() > 1 && base.back() == '/') base.pop_back();

    char stamp[32];
    const time_t now = time(nullptr);
    struct tm tmv;
    localtime_r(&now, &tmv);
    if (strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &tmv) == 0) {
        std::snprintf(stamp, sizeof stamp, "%lu", (unsigned long)now);
    }

    return base + "/iec-" + std::to_string((long)getpid()) + "-" + stamp + ".log";
}

Logger::Logger() : file_path_(DefaultLogPath()) {
    const char* debug = getenv("IEC_LOG_DEBUG");
    debug_ = debug != nullptr && *debug != '\0' && std::strcmp(debug, "0") != 0;
}

Logger* Logger::GetInstance() {
    static Logger instance;
    return &instance;
}

void Logger::LogD(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(3, fmt, ap);
    va_end(ap);
}

void Logger::LogI(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(0, fmt, ap);
    va_end(ap);
}

void Logger::LogW(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(1, fmt, ap);
    va_end(ap);
}

void Logger::LogE(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    LogV(2, fmt, ap);
    va_end(ap);
}

void Logger::LogV(int level, const char* fmt, va_list ap) {
    if (!fmt) return;
    // Debug carries argv/env; keep it out of every sink unless asked for.
    if (level >= 3) {
        std::lock_guard<std::mutex> lk(mu_);
        if (!debug_) return;
    }

    char buf[2048];
    vsnprintf(buf, sizeof buf, fmt, ap);
    const std::string tagged =
        Redact(std::string("[") + LevelTag(level) + "] " + buf);

    std::lock_guard<std::mutex> lk(mu_);

    if (log_stderr_) {
        fprintf(stderr, "%s\n", tagged.c_str());
        fflush(stderr);
    }

    if (custom_writer_) {
        try {
            custom_writer_(level, tagged);
        } catch (...) {
            // A sink must not take the process down.
        }
    }

    if (log_file_ && !file_path_.empty()) {
        const size_t slash = file_path_.find_last_of('/');
        if (slash != std::string::npos) {
            mkdir(file_path_.substr(0, slash).c_str(), 0755);  // EEXIST is fine
        }

        const off_t add = static_cast<off_t>(tagged.size()) + 1;
        if (!file_size_known_) {
            struct stat st {};
            file_bytes_ = stat(file_path_.c_str(), &st) == 0 ? st.st_size : 0;
            file_size_known_ = true;
        }
        if (file_bytes_ > 0 && file_bytes_ + add > kMaxFileBytes) {
            // .2 is the oldest; drop it, shift .1 down, then the live file.
            const std::string oldest = file_path_ + "." + std::to_string(kMaxRotations);
            unlink(oldest.c_str());
            for (int i = kMaxRotations - 1; i >= 1; i--) {
                const std::string from = file_path_ + "." + std::to_string(i);
                const std::string to = file_path_ + "." + std::to_string(i + 1);
                rename(from.c_str(), to.c_str());
            }
            rename(file_path_.c_str(), (file_path_ + ".1").c_str());
            file_bytes_ = 0;
        }
        if (FILE* f = fopen(file_path_.c_str(), "a")) {
            fprintf(f, "%s\n", tagged.c_str());
            fclose(f);
            file_bytes_ += add;
        }
    }
}

void Logger::SetStderr(bool on) { std::lock_guard<std::mutex> lk(mu_); log_stderr_ = on; }
void Logger::SetFile(bool on)   { std::lock_guard<std::mutex> lk(mu_); log_file_ = on; }
void Logger::SetDebug(bool on)  { std::lock_guard<std::mutex> lk(mu_); debug_ = on; }

void Logger::SetCustomWriter(CustomWriter writer) {
    std::lock_guard<std::mutex> lk(mu_);
    custom_writer_ = std::move(writer);
}

bool Logger::StderrEnabled() const { std::lock_guard<std::mutex> lk(mu_); return log_stderr_; }
bool Logger::FileEnabled() const   { std::lock_guard<std::mutex> lk(mu_); return log_file_; }
bool Logger::DebugEnabled() const  { std::lock_guard<std::mutex> lk(mu_); return debug_; }

void Logger::SetLogFilePath(const std::string& path) {
    std::lock_guard<std::mutex> lk(mu_);
    if (!path.empty()) {
        file_path_ = path;
        file_bytes_ = 0;
        file_size_known_ = false;
    }
}

std::string Logger::LogFilePath() const {
    std::lock_guard<std::mutex> lk(mu_);
    return file_path_;
}
