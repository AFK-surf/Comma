//go:build !windows

package main

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

func acquireAndroidOwnerLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("another Connector owns this Android runtime: %w", err)
	}
	return f, nil
}
