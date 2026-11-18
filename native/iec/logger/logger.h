// logger/logger.h — a small printf-style logger with runtime-selectable sinks.
//
// The two sinks implemented here are:
//   stderr — the process's own stderr (on by default)
//   file   — one file per process under IEC_LOG_DIR (compile-time), or
//            $IEC_LOG_DIR / $HOME/logs, named with pid + timestamp
//   custom — an optional callback registered with SetCustomWriter(), called
//            for every line alongside the sinks above
//
// TTY output and hilog are deliberately not implemented in this module.
#pragma once

#include <sys/types.h>

#include <cstdarg>
#include <functional>
#include <mutex>
#include <string>

class Logger {
public:
    static Logger* GetInstance();

    void LogD(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void LogI(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void LogW(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void LogE(const char* fmt, ...) __attribute__((format(printf, 2, 3)));

    // Sinks are runtime-switchable and thread-safe.
    void SetStderr(bool on);
    void SetFile(bool on);

    // Debug lines are off by default; IEC_LOG_DEBUG=1 in the environment turns
    // them on at construction. They carry the full argv/env of a command, so a
    // normal build never writes those to disk.
    void SetDebug(bool on);
    bool DebugEnabled() const;

    bool StderrEnabled() const;
    bool FileEnabled() const;

    // Masks credentials in one line: token=/Authorization/Bearer/*_KEY/
    // *_TOKEN/password/secret/cookie. Every sink goes through this, so an
    // explicit call is only needed for text that is not logged directly.
    static std::string Redact(const std::string& text);

    // Passing an empty path leaves the current value unchanged.
    void SetLogFilePath(const std::string& path);
    std::string LogFilePath() const;

    // Custom sink: level 0/1/2 and the tagged line ("[I] ...").
    using CustomWriter = std::function<void(int level, const std::string& line)>;
    void SetCustomWriter(CustomWriter writer);

private:
    Logger();
    Logger(const Logger&) = delete;
    Logger& operator=(const Logger&) = delete;

    void LogV(int level, const char* fmt, va_list ap);

    mutable std::mutex mu_;
    // level: 0 = Info, 1 = Warn, 2 = Error (see LogI/LogW/LogE)
    bool log_stderr_ = true;
    bool log_file_ = true;
    bool debug_ = false;
    std::string file_path_;
    CustomWriter custom_writer_;
    // Size tracking for the file sink's size-based rotation. Known is false
    // until the first write to a newly selected path.
    off_t file_bytes_ = 0;
    bool file_size_known_ = false;
};
