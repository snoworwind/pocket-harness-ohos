// exec/exec_route.h — what the routes have to share with each other.
//
// Every way a program can be started lives in its own file and answers to one function, and
// those functions are of two kinds: the resolvers, which work out what a path means here,
// and the routers, which start it. A route that has to hand a program on to another route --
// the interpreter of a script, say -- needs both, which is what this declares. The
// definitions stay where they belong, next to the code that owns them.
#pragma once

#include <sys/stat.h>
#include <sys/types.h>

#include <string>
#include <vector>

#include "exec_types.h"

// An absolute path as this host really has it: inside the fake root when the capabilities
// say the app sandbox is all there is, unchanged otherwise. Relative paths are left alone --
// they are relative to a working directory -- and so is the empty string.
std::string UnderFakeRoot(const std::string& path);

// The path a name is started from: searched in PATH when it has no slash of its own, or
// empty when nothing matches. Runs in the parent, before the fork.
std::string ResolveFilePath(const std::string& path, const std::vector<std::string>& env,
                            const std::string& cwd);

// Follows the two forms of symbolic link this runtime can meet -- a real one, and the
// fs shim's `<name>.IEC_SYMLINK` marker file -- and returns the file they name. A path
// that is not a link (and has none on the way) comes back unchanged, so callers can use
// this on every request. Relative paths are resolved against `cwd`, exactly like
// ResolveAgainstCwd() in the server does before this is called.
//
// The kernel resolves a real symlink itself, but it cannot resolve the marker form: a
// launcher reached through `ln -s` is a marker file there, and routing has to see the
// launcher underneath it or the file is refused as unexecutable.
std::string ResolveLaunchPath(const std::string& path, const std::string& cwd);

// The mode the fs shim stored in <path>.IEC_CHMOD when the kernel refused a
// chmod. These three are how the server honours an emulated executable bit:
// ReadChmodMarker reads it, ModeAllowsExec applies the usual uid/gid rules,
// and EmulatedExecutable is the "does this file only look executable because
// of a sidecar?" question that routing asks before choosing kExec.
bool ReadChmodMarker(const std::string& path, mode_t* mode);
bool ModeAllowsExec(mode_t mode, const struct stat& st);
bool EmulatedExecutable(const std::string& path);

// How a program of this host is started; see exec_types.h for what the kinds mean.
LaunchKind ResolveKind(const std::string& path);

// Based on the previously determined kind, the request is routed to different 
// functions for execution.
[[noreturn]] void StartByKind(LaunchKind kind, const SpawnRequest& req);

// fork + execve, for a program of the architecture this server runs on. Returns only on
// failure.
pid_t SpawnExec(const SpawnRequest& req);
