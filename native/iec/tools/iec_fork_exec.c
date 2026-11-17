// tools/iec_fork_exec.c — a fork+exec for programs that cannot use execve.
//
// On HarmonyOS the application sandbox denies execve() of ELF files anywhere
// (app data, bundle libs and even the system loader return EACCES), so a Go
// program's os/exec cannot start the runtime's command launchers. What it can
// still do is fork: this helper forks, and in the child calls the IEC exec
// shim's execve() -- the same call every C command object makes -- which asks
// the exec service to start the launcher's .so and turns the child into the
// stand-in for that program. The parent keeps an ordinary child pid, so the
// usual waitpid()/os.Process.Wait() works.
//
// The child runs only C code (dup2, chdir, one RPC call and then the stand-in
// loop), so it does not touch the Go runtime after fork.
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

// From exec/shim.c (linked into the same object as a cgo C file).
extern int execve(const char *path, char *const argv[], char *const envp[]);

// Starts `file` (an #IECSOv2 launcher or a dual-form command) through the IEC
// exec service with the given stdio descriptors. A descriptor of -1 means
// /dev/null. Returns the child pid, or -1 with errno set. argv and envp must be
// NULL-terminated; cwd may be NULL to inherit.
pid_t iec_fork_exec(const char *file, char **argv, char **envp, const char *cwd,
                    int in_fd, int out_fd, int err_fd) {
    const pid_t pid = fork();
    if (pid != 0) return pid;

    if (cwd != NULL && *cwd != '\0' && chdir(cwd) != 0) _exit(127);

    int devnull = -1;
    if (in_fd < 0 || out_fd < 0 || err_fd < 0) {
        devnull = open("/dev/null", O_RDWR);
    }
    const int in = in_fd >= 0 ? in_fd : devnull;
    const int out = out_fd >= 0 ? out_fd : devnull;
    const int err = err_fd >= 0 ? err_fd : devnull;
    if (in >= 0) dup2(in, STDIN_FILENO);
    if (out >= 0) dup2(out, STDOUT_FILENO);
    if (err >= 0) dup2(err, STDERR_FILENO);
    if (devnull > STDERR_FILENO) close(devnull);

    execve(file, argv, envp);
    _exit(125);
}
