//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestManagedPiAuthOpenDoesNotBlockAfterRegularFileBecomesFIFO(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth.json")
	if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		file, err := openManagedPiAuthFile(path)
		if file != nil {
			file.Close()
		}
		done <- err
	}()
	select {
	case <-done:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("managed Pi auth open blocked on replacement FIFO")
	}
}
