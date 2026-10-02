package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
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
	select {
	case err := <-done:
		runtime.writeMu.Unlock()
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("blocked native write returned %v", err)
		}
	case <-time.After(time.Second):
		runtime.writeMu.Unlock()
		<-done
		t.Fatal("native RPC deadline did not cover its write lock")
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
	defer c.closeExternalRuntimes()
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
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("non-reading native peer returned success")
		}
	case <-time.After(2 * time.Second):
		_ = ws.Close()
		<-done
		t.Fatal("native RPC deadline did not cover the socket write")
	}
	releaseOnce.Do(func() { close(release) })
	select {
	case <-readDone:
	case <-time.After(time.Second):
		t.Fatal("failed socket remained registered after the native peer resumed reading")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
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

func TestCloudQuietDeadlineDoesNotTransferLockedOwner(t *testing.T) {
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c := &connector{}
	c.cloudRuntimeMu.Lock()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "archive-one"})
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("quiet behind current owner returned %v", err)
		}
	case <-time.After(time.Second):
		c.cloudRuntimeMu.Unlock()
		<-done
		t.Fatal("quiet continued to wait after its deadline")
	}
	if c.cloudRuntimeQuiesced || c.cloudRuntimeReleased {
		t.Fatal("timed-out quiet granted release authority")
	}
	c.cloudRuntimeMu.Unlock()
}

func TestCodexQuietInspectsSlowSessionsWithBoundedConcurrency(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	gate := make(chan struct{})
	var gateOnce sync.Once
	var received, active, maximum atomic.Int32
	var writes sync.Mutex
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var replies sync.WaitGroup
		defer func() {
			gateOnce.Do(func() { close(gate) })
			replies.Wait()
		}()
		for {
			var request map[string]any
			if ws.ReadJSON(&request) != nil {
				return
			}
			current := active.Add(1)
			for previous := maximum.Load(); current > previous; previous = maximum.Load() {
				if maximum.CompareAndSwap(previous, current) {
					break
				}
			}
			if received.Add(1) == 2 {
				gateOnce.Do(func() { close(gate) })
			}
			replies.Go(func() {
				select {
				case <-gate:
				case <-r.Context().Done():
					return
				}
				writes.Lock()
				defer writes.Unlock()
				active.Add(-1)
				_ = ws.WriteJSON(map[string]any{"id": request["id"], "result": map[string]any{"data": []any{}}})
			})
		}
	}))
	defer server.Close()
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &codexRuntime{ws: ws, done: make(chan struct{}), pending: map[string]chan map[string]any{}}
	defer runtime.close()
	go runtime.readLoop(ws)
	implementation := newCodexRuntimeImplementation(c)
	for number := range 26 {
		id := fmt.Sprintf("ses1_%019d", number+1)
		implementation.sessions[id] = &codexRuntimeSession{sessionID: id, runtime: runtime, threadID: fmt.Sprintf("native-%d", number), workState: "settled"}
		appendRuntimeSessionID(&implementation.sessionOrder, &implementation.sessionIndex, id)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := implementation.Quiet(ctx); err != nil {
		t.Fatal(err)
	}
	if received.Load() != 26 || maximum.Load() < 2 || maximum.Load() > 4 {
		t.Fatalf("native quiet queries=%d peak=%d", received.Load(), maximum.Load())
	}
}
