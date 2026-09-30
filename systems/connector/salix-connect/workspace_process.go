package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// findWorkspaceProcesses returns the pids and cwds of processes whose
// working directory is inside workspace (session-owned strays such as dev
// servers left running by an agent). Shared runtime processes must never be
// terminated: callers pass their pids via protected, and the cwd whitelist
// means a shared app-server running outside session workspaces is never
// matched anyway.
func findWorkspaceProcesses(workspace string, protected map[int]struct{}) map[int]string {
	pids, err := allPIDs()
	if err != nil || len(pids) == 0 {
		return nil
	}
	// lsof reports resolved paths (/var -> /private/var on macOS), so match
	// against the symlink-resolved workspace alongside the raw path.
	resolved := workspace
	if canonical, err := filepath.EvalSymlinks(workspace); err == nil {
		resolved = canonical
	}
	own := os.Getpid()
	strays := make(map[int]string)
	for pid, cwd := range workspaceCWDs(pids) {
		if pid <= 1 || pid == own {
			continue
		}
		if _, isProtected := protected[pid]; isProtected {
			continue
		}
		if cwd == workspace || strings.HasPrefix(cwd, workspace+"/") ||
			cwd == resolved || strings.HasPrefix(cwd, resolved+"/") {
			strays[pid] = cwd
		}
	}
	return strays
}

// killWorkspaceProcesses SIGTERMs every stray inside workspace, waits up to
// five seconds, then SIGKILLs survivors. It returns one log line per signal
// delivered.
func killWorkspaceProcesses(ctx context.Context, workspace string, protected map[int]struct{}) []string {
	strays := findWorkspaceProcesses(workspace, protected)
	if len(strays) == 0 {
		return nil
	}
	var lines []string
	for pid := range strays {
		if err := syscall.Kill(pid, syscall.SIGTERM); err == nil {
			lines = append(lines, fmt.Sprintf("sigterm pid=%d cwd=%s", pid, strays[pid]))
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			break
		}
		alive := 0
		for pid := range strays {
			if processAlive(pid) {
				alive++
			}
		}
		if alive == 0 {
			return lines
		}
		time.Sleep(200 * time.Millisecond)
	}
	for pid := range strays {
		if processAlive(pid) {
			if err := syscall.Kill(pid, syscall.SIGKILL); err == nil {
				lines = append(lines, fmt.Sprintf("sigkill pid=%d cwd=%s", pid, strays[pid]))
			}
		}
	}
	return lines
}

// processAlive reports whether pid is a live (non-zombie) process. Signal 0
// succeeds on unreaped zombies of our own children, so consult the process
// state as well.
func processAlive(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	state, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return true
	}
	return !strings.HasPrefix(strings.TrimSpace(string(state)), "Z")
}

func allPIDs() ([]int, error) {
	out, err := exec.Command("ps", "-axo", "pid=").Output()
	if err != nil {
		return nil, err
	}
	var pids []int
	for _, field := range strings.Fields(string(out)) {
		if pid, err := strconv.Atoi(field); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids, nil
}

// workspaceCWDs resolves each pid's working directory via lsof, filtered to
// the cwd file descriptor. One batched invocation covers all pids.
func workspaceCWDs(pids []int) map[int]string {
	cwds := make(map[int]string, len(pids))
	const batch = 128
	for start := 0; start < len(pids); start += batch {
		end := start + batch
		if end > len(pids) {
			end = len(pids)
		}
		args := []int(pids[start:end])
		arguments := []string{"-nP", "-w", "-a", "-d", "cwd", "-F", "pn", "-p"}
		identifiers := make([]string, len(args))
		for i, pid := range args {
			identifiers[i] = strconv.Itoa(pid)
		}
		arguments = append(arguments, strings.Join(identifiers, ","))
		// lsof exits non-zero when some processes are unreadable (running as
		// a non-root user); the readable ones are still on stdout, so parse
		// the output regardless of the exit status.
		out, _ := exec.Command("lsof", arguments...).Output()
		var current int
		for _, line := range strings.Split(string(out), "\n") {
			if line == "" {
				continue
			}
			switch line[0] {
			case 'p':
				current, _ = strconv.Atoi(line[1:])
			case 'n':
				if current != 0 {
					cwds[current] = line[1:]
				}
			}
		}
	}
	return cwds
}

// runtimeProcessPIDs collects the pids of live shared runtime processes
// (native app-servers and similar) so idle-session cleanup can never
// terminate them.
func runtimeProcessPIDs(implementations map[string]externalRuntimeImplementation) map[int]struct{} {
	protected := make(map[int]struct{})
	for _, implementation := range implementations {
		host, ok := implementation.(interface {
			RuntimePIDs() []int
		})
		if !ok {
			continue
		}
		for _, pid := range host.RuntimePIDs() {
			if pid > 0 {
				protected[pid] = struct{}{}
			}
		}
	}
	return protected
}
