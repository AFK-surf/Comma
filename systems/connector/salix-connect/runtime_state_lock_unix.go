//go:build !windows

package main

import (
	"os"

	"golang.org/x/sys/unix"
)

func lockRuntimeStateFile(f *os.File) error {
	return unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
}
