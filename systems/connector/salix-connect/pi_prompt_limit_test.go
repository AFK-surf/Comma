package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A native process must receive the complete prompt even beyond Linux's
// per-argument exec limit. This is a behavioral process-start regression.
func TestPiStartsWithLargeSystemPrompt(t *testing.T) {
	command := fakePortableRuntimeCommand(t, "pi")
	for _, size := range []int{1024, 160 * 1024} {
		t.Run(fmt.Sprintf("%d_bytes", size), func(t *testing.T) {
			c, err := newConnector(config{name: "prompt-limit", root: t.TempDir(), systemInfoInterval: 0})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			defer func() {
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
			}()
			implementation := c.runtimeImplementations["pi"].(*piRuntimeImplementation)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			session, err := implementation.startSession(ctx, externalRuntimeInput{sessionID: "prompt-limit", command: command, workspace: t.TempDir(), systemPrompt: strings.Repeat("p", size)})
			if err != nil {
				t.Fatalf("prompt_bytes=%d start failed: %v", size, err)
			}
			var path string
			for j, arg := range session.cmd.Args {
				if arg == "--append-system-prompt" {
					path = session.cmd.Args[j+1]
				}
			}
			if !filepath.IsAbs(path) {
				t.Fatalf("prompt path is not absolute")
			}
			contents, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(contents) != externalRuntimeSystemPrompt(strings.Repeat("p", size)) {
				t.Fatal("prompt content changed")
			}
			info, err := os.Stat(path)
			if err != nil || info.Mode().Perm() != 0600 {
				t.Fatal("prompt must be private")
			}
			session.stop()
			<-session.done
			deadline := time.Now().Add(time.Second)
			for {
				_, err := os.Stat(path)
				if os.IsNotExist(err) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("exited process retained prompt file")
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
}

func TestPiPromptFileRemovedAfterStartFailure(t *testing.T) {
	c, err := newConnector(config{name: "prompt-failure", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	defer func() {
		if c.bridgeServer != nil {
			_ = c.bridgeServer.Shutdown(context.Background())
		}
	}()
	impl := c.runtimeImplementations["pi"].(*piRuntimeImplementation)
	_, err = impl.startSession(context.Background(), externalRuntimeInput{sessionID: "failed", command: filepath.Join(t.TempDir(), "missing-pi"), workspace: t.TempDir(), systemPrompt: "private"})
	if err == nil {
		t.Fatal("missing executable unexpectedly started")
	}
	matches, err := filepath.Glob(filepath.Join(c.runtimeStateRoot(), "external-runtime", "pi", "failed", "system-prompt-*.txt"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("startup failure retained prompt: %v", matches)
	}
}
