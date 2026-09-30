//go:build windows

package main

import "os"

func openManagedPiAuthFile(path string) (*os.File, error) {
	return os.Open(path)
}
