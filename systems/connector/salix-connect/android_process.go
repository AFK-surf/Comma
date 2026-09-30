//go:build !windows

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// The administrator reserves these AVD names and serial for this Connector.
// A Linux process handle fences signals against PID reuse. This is process
// ownership, not authentication against a hostile host owner.
type androidOwnedProcess struct {
	process *os.Process
	profile string
	done    <-chan struct{}
}

func (o *androidOwnedProcess) alive() bool {
	if o.done != nil {
		select {
		case <-o.done:
			return false
		default:
			return true
		}
	}
	return o.process.Signal(syscall.Signal(0)) == nil
}
func (o *androidOwnedProcess) release() { _ = o.process.Release() }

func (p *androidProvider) stopProcess(ctx context.Context) error {
	owned := p.process
	if owned == nil {
		return nil
	}
	if owned.alive() {
		if err := owned.process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return err
		}
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for owned.alive() {
			select {
			case <-ctx.Done():
				return errors.New("owned emulator did not stop before deadline")
			case <-ticker.C:
			}
		}
	}
	owned.release()
	p.process = nil
	p.mu.Lock()
	p.activeProfile = ""
	p.mu.Unlock()
	return nil
}

func readAndroidSmallFile(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("Android ownership file exceeds limit")
	}
	return data, nil
}

// At most eight configured AVD locks are read, without a process-table scan.
// Missing locks are normal for stopped AVDs. Ambiguous ownership fails closed.
func (p *androidProvider) discoverProcess(ctx context.Context) (*androidOwnedProcess, error) {
	var found *androidOwnedProcess
	fail := func(err error) (*androidOwnedProcess, error) {
		if found != nil {
			found.release()
		}
		return nil, err
	}
	for _, profile := range p.profiles.Profiles {
		data, err := readAndroidSmallFile(filepath.Join(p.cfg.androidAVDHome, profile.AVDName+".avd", "hardware-qemu.ini.lock"), 64)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fail(errors.New("cannot read configured AVD ownership lock"))
		}
		pid, err := strconv.Atoi(strings.TrimSpace(strings.TrimRight(string(data), "\x00")))
		if err != nil || pid <= 1 {
			return fail(errors.New("configured AVD has an invalid ownership lock"))
		}
		process, err := os.FindProcess(pid)
		if err != nil {
			return fail(errors.New("cannot acquire emulator process handle"))
		}
		cmdline, err := readAndroidSmallFile(fmt.Sprintf("/proc/%d/cmdline", pid), 8192)
		if err != nil {
			process.Release()
			return fail(errors.New("AVD ownership lock is stale or unreadable; administrator action required"))
		}
		if !p.matchesAndroidProcess(cmdline, profile) {
			process.Release()
			return fail(errors.New("AVD process ownership does not match; administrator action required"))
		}
		candidate := &androidOwnedProcess{process: process, profile: profile.ID}
		if !candidate.alive() {
			candidate.release()
			return fail(errors.New("AVD ownership lock became stale; administrator action required"))
		}
		if found != nil {
			candidate.release()
			return fail(errors.New("multiple configured AVDs are running; administrator action required"))
		}
		found = candidate
	}
	if found == nil {
		output, err := p.adb(ctx, "get-state")
		if err == nil && strings.TrimSpace(string(output)) != "" {
			return nil, errors.New("Android serial is occupied by an unowned process")
		}
	}
	if err := ctx.Err(); err != nil {
		return fail(err)
	}
	return found, nil
}

func (p *androidProvider) matchesAndroidProcess(data []byte, profile androidProfileSpec) bool {
	args := strings.Split(strings.TrimRight(string(data), "\x00"), "\x00")
	if len(args) < 2 {
		return false
	}
	executable := filepath.Clean(args[0])
	validBinary := false
	for _, base := range []string{filepath.Join(p.cfg.androidSDKRoot, "emulator"), p.cfg.androidSDKRoot} {
		for _, name := range []string{"qemu-system-x86_64", "qemu-system-x86_64-headless"} {
			if executable == filepath.Join(base, "qemu", "linux-x86_64", name) {
				validBinary = true
			}
		}
	}
	avd, port := false, false
	for i, arg := range args[1:] {
		if arg == "@"+profile.AVDName {
			avd = true
		}
		if arg == "-port" && i+2 < len(args) && args[i+2] == strings.TrimPrefix(p.cfg.androidSerial, "emulator-") {
			port = true
		}
	}
	return validBinary && avd && port
}
