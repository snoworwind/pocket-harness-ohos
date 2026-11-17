// bridge.go — start the runtime's command launchers without execve.
//
// HarmonyOS denies execve() of ELF files in every path the app can see, so Go's
// os/exec cannot start <sysroot>/bin/git. IEC's own command objects ask the exec
// service over a Unix socket instead; this package does the same from gh:
//
//   * fork() in C (the child runs only C code; see iec_fork_exec.c),
//   * the child calls the linked exec shim, sends the request and becomes the
//     stand-in for the program the service started,
//   * the parent keeps an ordinary child pid, so os.Process.Wait works and
//     stdout/stderr flow through ordinary pipes.
package ghohos

/*
#include <stdlib.h>
#include <sys/types.h>
pid_t iec_fork_exec(const char *file, char **argv, char **envp, const char *cwd,
                    int in_fd, int out_fd, int err_fd);
*/
import "C"

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"unsafe"
)

// IsLauncher reports whether path is one of the runtime's command entry points.
func IsLauncher(path string) bool {
	root := os.Getenv("IEC_SYSROOT")
	return root != "" && strings.HasPrefix(path, root+"/bin/")
}

type state struct {
	wg sync.WaitGroup
}

func cStringArray(values []string) ([]*C.char, func()) {
	arr := make([]*C.char, len(values)+1)
	for i, v := range values {
		arr[i] = C.CString(v)
	}
	return arr, func() {
		for _, p := range arr {
			if p != nil {
				C.free(unsafe.Pointer(p))
			}
		}
	}
}

func cArray(values []*C.char) **C.char {
	return (**C.char)(unsafe.Pointer(&values[0]))
}

// closeChildPipe closes a pipe end installed by exec.Cmd.*Pipe: the forked child
// holds the dup, so the parent's copy has to go or the reader never sees EOF.
func closeChildPipe(v any) {
	f, ok := v.(*os.File)
	if !ok {
		return
	}
	st, err := f.Stat()
	if err != nil {
		return
	}
	if st.Mode()&os.ModeNamedPipe != 0 {
		f.Close()
	}
}

// Start forks a child that asks the exec service to start cmd.Path with cmd.Args.
func Start(cmd *exec.Cmd) error {
	if cmd.Path == "" {
		return errors.New("ghohos: empty command path")
	}
	env := cmd.Env
	if env == nil {
		env = os.Environ()
	}
	st := &state{}

	inFd := -1
	switch v := cmd.Stdin.(type) {
	case nil:
	case *os.File:
		inFd = int(v.Fd())
	default:
		pr, pw, err := os.Pipe()
		if err != nil {
			return err
		}
		inFd = int(pr.Fd())
		st.wg.Add(1)
		go func() {
			defer st.wg.Done()
			_, _ = io.Copy(pw, v)
			pw.Close()
		}()
		defer pr.Close()
	}

	outFd := -1
	var stdoutPipe *os.File
	switch v := cmd.Stdout.(type) {
	case nil:
	case *os.File:
		outFd = int(v.Fd())
	default:
		pr, pw, err := os.Pipe()
		if err != nil {
			return err
		}
		outFd = int(pw.Fd())
		stdoutPipe = pw
		st.wg.Add(1)
		go func() {
			defer st.wg.Done()
			_, _ = io.Copy(v, pr)
			pr.Close()
		}()
	}

	errFd := -1
	var stderrPipe *os.File
	switch v := cmd.Stderr.(type) {
	case nil:
	case *os.File:
		errFd = int(v.Fd())
	default:
		pr, pw, err := os.Pipe()
		if err != nil {
			return err
		}
		errFd = int(pw.Fd())
		stderrPipe = pw
		st.wg.Add(1)
		go func() {
			defer st.wg.Done()
			_, _ = io.Copy(v, pr)
			pr.Close()
		}()
	}

	var cwd *C.char
	if cmd.Dir != "" {
		cwd = C.CString(cmd.Dir)
		defer C.free(unsafe.Pointer(cwd))
	}
	file := C.CString(cmd.Path)
	defer C.free(unsafe.Pointer(file))
	argv, freeArgv := cStringArray(cmd.Args)
	defer freeArgv()
	envv, freeEnv := cStringArray(env)
	defer freeEnv()

	pid := C.iec_fork_exec(file, cArray(argv), cArray(envv), cwd,
		C.int(inFd), C.int(outFd), C.int(errFd))

	if stdoutPipe != nil {
		stdoutPipe.Close()
	}
	if stderrPipe != nil {
		stderrPipe.Close()
	}
	closeChildPipe(cmd.Stdin)
	closeChildPipe(cmd.Stdout)
	closeChildPipe(cmd.Stderr)
	if pid < 0 {
		return errors.New("ghohos: cannot start " + cmd.Path)
	}

	cmd.Process, _ = os.FindProcess(int(pid))
	return nil
}

// Wait waits for the stand-in child and records its status on cmd.
func Wait(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return errors.New("ghohos: command was not started")
	}
	ps, err := cmd.Process.Wait()
	cmd.ProcessState = ps
	if err != nil {
		return err
	}
	if ps == nil || !ps.Success() {
		return &exec.ExitError{ProcessState: ps}
	}
	return nil
}

// Run starts cmd and waits for it. Non-launcher commands use os/exec unchanged.
func Run(cmd *exec.Cmd) error {
	if !IsLauncher(cmd.Path) {
		return cmd.Run()
	}
	if err := Start(cmd); err != nil {
		return err
	}
	return Wait(cmd)
}

// Output is exec.Cmd.Output for a launcher, including Stderr on the returned
// *exec.ExitError (gh builds its user-facing errors from it).
func Output(cmd *exec.Cmd) ([]byte, error) {
	if !IsLauncher(cmd.Path) {
		return cmd.Output()
	}
	var out, errb bytes.Buffer
	if cmd.Stdout == nil {
		cmd.Stdout = &out
	}
	if cmd.Stderr == nil {
		cmd.Stderr = &errb
	}
	err := Run(cmd)
	if ee, ok := err.(*exec.ExitError); ok {
		ee.Stderr = errb.Bytes()
	}
	return out.Bytes(), err
}
