//go:build darwin

package main

import "golang.org/x/sys/unix"

// swapComputerUseHelper exchanges two existing directories in one step.
var swapComputerUseHelper = func(a, b string) error {
	return unix.RenamexNp(a, b, unix.RENAME_SWAP)
}
