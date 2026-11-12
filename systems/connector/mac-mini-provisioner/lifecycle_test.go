//go:build darwin || linux

package main

import (
	"bufio"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestLifecycleOwnerOutlivesObservation(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	var pipes []*os.File
	for _, name := range []string{"events", "continue"} {
		path := filepath.Join(directory, name)
		if err := syscall.Mkfifo(path, 0600); err != nil {
			t.Fatal(err)
		}
		pipe, err := os.OpenFile(path, os.O_RDWR, 0600)
		if err != nil {
			t.Fatal(err)
		}
		pipes = append(pipes, pipe)
		t.Cleanup(func() { pipe.Close() })
	}
	helper := filepath.Join(directory, "owner")
	script := `#!/bin/sh
directory=$(dirname "$0")
case "$*" in
 *repair*)
  printf '{"requestId":"request-detached","outcome":"pending"}\n' > "$directory/receipt"
  printf 'ready\n' > "$directory/events"
  read -r proceed < "$directory/continue"
  printf '{"requestId":"request-detached","outcome":"succeeded"}\n' > "$directory/receipt"
  printf 'settled\n' > "$directory/events"
  ;;
 *) cat "$directory/receipt" ;;
esac
`
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	observed := make(chan error, 1)
	go func() {
		_, err := runDetachedLifecycle(ctx, helper, []string{"repair", "--request-id", "request-detached"}, nil)
		observed <- err
	}()
	reader := bufio.NewReader(pipes[0])
	if line, err := reader.ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("owner readiness = %q, %v", line, err)
	}
	cancel()
	if err := <-observed; !errors.Is(err, context.Canceled) {
		t.Fatalf("observation = %v", err)
	}
	if _, err := pipes[1].WriteString("continue\n"); err != nil {
		t.Fatal(err)
	}
	if line, err := reader.ReadString('\n'); err != nil || line != "settled\n" {
		t.Fatalf("owner settlement = %q, %v", line, err)
	}
	output, err := runDetachedLifecycle(context.Background(), helper, []string{"operation", "--request-id", "request-detached"}, nil)
	if err != nil || !strings.Contains(string(output), `"outcome":"succeeded"`) || !strings.Contains(string(output), `"requestId":"request-detached"`) {
		t.Fatalf("same request = %s, %v", output, err)
	}
}
