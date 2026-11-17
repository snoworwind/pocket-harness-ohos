// iec.go — start the runtime's command launchers without execve.
//
// HarmonyOS denies execve() of ELF files in every path the app can see (app
// data, bundle libs, even the system loader all return EACCES), so Go's os/exec
// cannot start <sysroot>/bin/git. IEC's own command objects do not use execve:
// they ask the exec service over a Unix socket, and the service loads the .so
// and creates the process. This file does the same from Go:
//
//   * fork() in C (the child runs only C code; see tools/iec_fork_exec.c),
//   * the child calls the linked exec shim, which sends the request and becomes
//     the stand-in for the program the service started,
//   * the parent keeps an ordinary child pid, so os.Process.Wait() works and
//     stdout/stderr flow through ordinary pipes.
package subprocess

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

// isIecLauncher reports whether path is one of the runtime's command entry
// points (the ones listed in runtime-manifest.json and written by the app).
func isIecLauncher(path string) bool {
	root := os.Getenv("IEC_SYSROOT")
	return root != "" && strings.HasPrefix(path, root+"/bin/")
}

// iecState is what a started IEC child needs after Start returns.
type iecState struct {
	pid int
	wg  sync.WaitGroup
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

// closeChildEnd closes a pipe end that exec.Cmd.StdoutPipe/StderrPipe/StdinPipe
// installed in the Cmd. os/exec normally closes those copies itself after Start;
// this implementation has to do it, or the reader never sees EOF. A real file,
// tty or socket (os.Stdout, os.Stdin, a redirected file) is left alone.
func closeChildEnd(v any) {
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

// startIEC forks a child that asks the exec service to start c.Path with c.Args.
func (c *Cmd) startIEC() error {
	env := c.Cmd.Env
	if env == nil {
		env = os.Environ()
	}
	state := &iecState{}

	// stdin: pass the file through, or feed a writer through a pipe.
	inFd := -1
	switch v := c.Stdin.(type) {
	case nil:
		// /dev/null
	case *os.File:
		inFd = int(v.Fd())
	default:
		pr, pw, err := os.Pipe()
		if err != nil {
			return err
		}
		inFd = int(pr.Fd())
		state.wg.Add(1)
		go func() {
			defer state.wg.Done()
			_, _ = io.Copy(pw, v)
			pw.Close()
		}()
		defer pr.Close() // parent copy; the child has its own dup
	}

	outFd := -1
	var stdoutPipe *os.File
	switch v := c.Stdout.(type) {
	case nil:
		// /dev/null
	case *os.File:
		outFd = int(v.Fd())
	default:
		pr, pw, err := os.Pipe()
		if err != nil {
			return err
		}
		outFd = int(pw.Fd())
		stdoutPipe = pw
		state.wg.Add(1)
		go func() {
			defer state.wg.Done()
			_, _ = io.Copy(v, pr)
			pr.Close()
		}()
	}

	errFd := -1
	var stderrPipe *os.File
	switch v := c.Stderr.(type) {
	case nil:
		// /dev/null
	case *os.File:
		errFd = int(v.Fd())
	default:
		pr, pw, err := os.Pipe()
		if err != nil {
			return err
		}
		errFd = int(pw.Fd())
		stderrPipe = pw
		state.wg.Add(1)
		go func() {
			defer state.wg.Done()
			_, _ = io.Copy(v, pr)
			pr.Close()
		}()
	}

	var cwd *C.char
	if c.Cmd.Dir != "" {
		cwd = C.CString(c.Cmd.Dir)
		defer C.free(unsafe.Pointer(cwd))
	}
	file := C.CString(c.Cmd.Path)
	defer C.free(unsafe.Pointer(file))
	argv, freeArgv := cStringArray(c.Cmd.Args)
	defer freeArgv()
	envv, freeEnv := cStringArray(env)
	defer freeEnv()

	pid := C.iec_fork_exec(file, cArray(argv), cArray(envv), cwd,
		C.int(inFd), C.int(outFd), C.int(errFd))

	// The child has its own dup of each write end by now.
	if stdoutPipe != nil {
		stdoutPipe.Close()
	}
	if stderrPipe != nil {
		stderrPipe.Close()
	}
	// Pipe ends installed by exec.Cmd.*Pipe: the child holds the dup, so the
	// parent's copy has to go or the reader never reaches EOF.
	closeChildEnd(c.Stdin)
	closeChildEnd(c.Stdout)
	closeChildEnd(c.Stderr)
	if pid < 0 {
		return errors.New("iec: cannot start " + c.Cmd.Path)
	}

	state.pid = int(pid)
	c.iecState = state
	c.Cmd.Process, _ = os.FindProcess(int(pid))
	return nil
}

// waitIEC waits for the stand-in child, which exits with the started program's
// status, and reports it the way exec.Cmd.Wait does.
func (c *Cmd) waitIEC() error {
	state := c.iecState
	if state == nil || c.Cmd.Process == nil {
		return errors.New("iec: command was not started")
	}
	state.wg.Wait()
	ps, err := c.Cmd.Process.Wait()
	c.Cmd.ProcessState = ps
	if err != nil {
		return err
	}
	if ps == nil || !ps.Success() {
		return &exec.ExitError{ProcessState: ps}
	}
	return nil
}

// outputIEC mirrors exec.Cmd.Output for an IEC child, including Stderr on the
// returned *exec.ExitError (git-lfs uses it to build its error messages).
func (c *Cmd) outputIEC() ([]byte, error) {
	var out, errb bytes.Buffer
	if c.Stdout == nil {
		c.Stdout = &out
	}
	if c.Stderr == nil {
		c.Stderr = &errb
	}
	err := c.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		ee.Stderr = errb.Bytes()
	}
	return out.Bytes(), err
}

// combinedOutputIEC mirrors exec.Cmd.CombinedOutput.
func (c *Cmd) combinedOutputIEC() ([]byte, error) {
	if c.Stdout != nil {
		return nil, errors.New("exec: Stdout already set")
	}
	if c.Stderr != nil {
		return nil, errors.New("exec: Stderr already set")
	}
	var b bytes.Buffer
	c.Stdout = &b
	c.Stderr = &b
	err := c.Run()
	return b.Bytes(), err
}
