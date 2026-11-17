//go:build !windows
// +build !windows

package subprocess

import (
	"os/exec"
)

// ExecCommand is a small platform specific wrapper around os/exec.Command.
//
// On HarmonyOS the sandbox denies execve() of ELF files everywhere, and the
// runtime starts commands through #IECSOv2 launchers that only the IEC exec
// service can load. A launcher under $IEC_SYSROOT/bin is therefore started in
// process (fork + IEC exec RPC), not through execve; see iec.go.
func ExecCommand(name string, arg ...string) (*Cmd, error) {
	cmd := exec.Command(name, arg...)
	var err error
	cmd.Path, err = LookPath(name)
	if err != nil {
		return nil, err
	}
	cmd.Env = fetchEnvironment()

	wrapped := newCmd(cmd)
	if isIecLauncher(cmd.Path) {
		wrapped.iec = true
	}
	return wrapped, nil
}
