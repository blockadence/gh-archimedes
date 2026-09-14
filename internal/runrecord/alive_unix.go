//go:build unix

package runrecord

import "syscall"

// Signal 0 is the portable way to ask the kernel whether a pid is anybody's:
// it runs every check a real signal would and delivers nothing. ESRCH is the
// answer that means no such process; EPERM means there is one and it is not
// ours to signal, which is still a live process and still a reason not to
// touch the repo it is working in.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}
