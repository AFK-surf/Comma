//go:build windows

package main

import (
	"errors"
	"os"
)

func acquireAndroidOwnerLock(string) (*os.File, error) {
	return nil, errors.New("Android emulator control is supported only on Linux")
}
