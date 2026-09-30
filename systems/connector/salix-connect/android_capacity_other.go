//go:build !linux

package main

import "errors"

func checkAndroidHostCapacity(string) error {
	return errors.New("Android emulator control is supported only on Linux")
}
