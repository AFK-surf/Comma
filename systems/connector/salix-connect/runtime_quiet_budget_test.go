package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/gorilla/websocket"
)

func TestCodexRPCDeadlineIncludesWriteLock(t *testing.T) {
	runtime := &codexRuntime{pending: map[string]chan map[string]any{}}
	runtime.writeMu.Lock()
	done := make(chan error, 1)
	go func() {
		_, err := runtime.rpc(context.Background(), "thread/backgroundTerminals/list", nil, 50*time.Millisecond)
		done <- err
	}()
	// An RPC whose deadline ignored the write lock never returns; the go test
	// timeout reports it.
	err := <-done
	runtime.writeMu.Unlock()
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("blocked native write returned %v", err)
	}
	if len(runtime.pending) != 0 {
		t.Fatal("expired native RPC left a pending reply")
	}
}

func TestCodexRPCDeadlineIncludesSocketWrite(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "codex.log"), nil)
	c, err := newConnector(config{name: "quiet-write-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	release := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		<-release // The native peer does not read until after the write deadline.
		for {
			if _, _, err := ws.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	var releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(release) })
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	runtime := &codexRuntime{ws: ws, command: command, implementation: implementation,
		pending: map[string]chan map[string]any{}, exited: make(chan struct{})}
	implementation.mu.Lock()
	implementation.runtimes[command] = runtime
	implementation.mu.Unlock()
	readDone := make(chan struct{})
	go func() { runtime.readLoop(ws); close(readDone) }()
	defer func() { _ = ws.Close(); <-readDone }()
	done := make(chan error, 1)
	go func() {
		_, err := runtime.rpc(context.Background(), "read-only-fixture", map[string]any{"padding": strings.Repeat("x", 16<<20)}, 100*time.Millisecond)
		done <- err
	}()
	// An RPC whose deadline ignored the blocked socket write never returns;
	// the go test timeout reports it.
	if err := <-done; err == nil {
		t.Fatal("non-reading native peer returned success")
	}
	releaseOnce.Do(func() { close(release) })
	<-readDone
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	replacement, err := implementation.ensureTargetRuntime(ctx, runtimeProbeTarget{provider: "codex", identityMaterial: command})
	if err != nil {
		t.Fatalf("recover native transport: %v", err)
	}
	if replacement == runtime {
		t.Fatal("reused the socket with a permanent write failure")
	}
	if _, err := replacement.rpc(ctx, "account/read", nil, time.Second); err != nil {
		t.Fatalf("native request after transport recovery: %v", err)
	}
}

// The quiet polls for the lock and meets its deadline on the bubble's clock.
func TestCloudQuietDeadlineDoesNotTransferLockedOwner(t *testing.T) {
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	synctest.Test(t, func(t *testing.T) {
		c := &connector{}
		c.cloudRuntimeMu.Lock()
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()
		done := make(chan error, 1)
		go func() {
			_, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "archive-one"})
			done <- err
		}()
		// A quiet that waited past its deadline never returns; the go test
		// timeout reports it.
		if err := <-done; !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("quiet behind current owner returned %v", err)
		}
		if c.cloudRuntimeQuiesced || c.cloudRuntimeReleased {
			t.Fatal("timed-out quiet granted release authority")
		}
		c.cloudRuntimeMu.Unlock()
	})
}
