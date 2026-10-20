//go:build linux

package main

import "golang.org/x/sys/unix"

// The helper only runs on macOS; Linux keeps the runner's tests meaningful.
var swapComputerUseHelper = func(a, b string) error {
	return unix.Renameat2(unix.AT_FDCWD, a, unix.AT_FDCWD, b, unix.RENAME_EXCHANGE)
}
