package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestRequestOperationRebindsRunningReplyToReplacement(t *testing.T) {
	root := t.TempDir()
	fifo := filepath.Join(root, "blocked-read.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := newConnector(config{name: "test", root: root})
	if err != nil {
		t.Fatal(err)
	}
	oldReplies := make(chan message, 1)
	old := c.claimConnection(context.Background(), func(_ context.Context, reply message) error {
		oldReplies <- reply
		return nil
	}, nil)
	request := message{
		ID: "stable-operation", Type: "request", Method: "read",
		Params: map[string]any{"path": "blocked-read.fifo"},
	}
	if !old.startRequest(request, nil) {
		t.Fatal("old connection did not admit request")
	}
	waitForCondition(t, "running operation", func() bool { return len(c.requestSlots) == 1 })

	newReplies := make(chan message, 1)
	replacement := c.claimConnection(context.Background(), func(_ context.Context, reply message) error {
		newReplies <- reply
		return nil
	}, nil)
	defer replacement.close(context.Canceled)
	if !replacement.startRequest(request, nil) {
		t.Fatal("replacement did not rebind stable operation")
	}
	if len(c.requestSlots) != 1 {
		t.Fatalf("duplicate operation consumed another execution slot: %d", len(c.requestSlots))
	}

	writer, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("rebound")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	select {
	case reply := <-newReplies:
		if reply.ID != request.ID || reply.Type != "response" {
			t.Fatalf("replacement reply = %#v", reply)
		}
	case <-time.After(time.Second):
		t.Fatal("replacement did not receive running operation result")
	}
	select {
	case reply := <-oldReplies:
		t.Fatalf("old reply sink received result after rebind: %#v", reply)
	default:
	}
}

func TestRequestOperationReplaysCompletedResultAndRejectsIDConflict(t *testing.T) {
	c, err := newConnector(config{name: "test", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	var executions atomic.Int32
	old := c.claimConnection(context.Background(), func(context.Context, message) error {
		return errors.New("reply lost with old transport")
	}, nil)
	request := message{ID: "completed-operation", Type: "request", Method: "process_list"}
	if !old.startRequest(request, func() { executions.Add(1) }) {
		t.Fatal("old connection did not admit request")
	}
	waitForCondition(t, "completed operation", func() bool {
		return executions.Load() == 1 && len(c.requestSlots) == 0
	})

	replies := make(chan message, 2)
	replacement := c.claimConnection(context.Background(), func(_ context.Context, reply message) error {
		replies <- reply
		return nil
	}, nil)
	defer replacement.close(context.Canceled)
	if !replacement.startRequest(request, func() { executions.Add(100) }) {
		t.Fatal("replacement did not replay completed operation")
	}
	select {
	case reply := <-replies:
		if reply.ID != request.ID || reply.Type != "response" {
			t.Fatalf("replayed reply = %#v", reply)
		}
	case <-time.After(time.Second):
		t.Fatal("completed result was not replayed")
	}

	conflict := message{
		ID: request.ID, Type: "request", Method: "stat", Params: map[string]any{"path": "."},
	}
	if !replacement.startRequest(conflict, func() { executions.Add(1000) }) {
		t.Fatal("id conflict did not produce a bounded error reply")
	}
	select {
	case reply := <-replies:
		if reply.Type != "error" || reply.Error != "request id reused with different method or params" {
			t.Fatalf("id conflict reply = %#v", reply)
		}
	case <-time.After(time.Second):
		t.Fatal("id conflict did not reply")
	}
	if got := executions.Load(); got != 1 {
		t.Fatalf("stable operation executed %d times", got)
	}
}

func TestReplyReleasesRequestAdmissionBeforeCallerStartsNextRequest(t *testing.T) {
	c, err := newConnector(config{name: "test", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	c.requestSlots = make(chan struct{}, 1)

	second := message{ID: "second", Type: "request", Method: "process_list"}
	secondAdmission := make(chan bool, 1)
	replies := make(chan message, 2)
	var session *connectionSession
	session = c.claimConnection(context.Background(), func(_ context.Context, reply message) error {
		if reply.ID == "first" {
			secondAdmission <- session.startRequest(second, nil)
		}
		replies <- reply
		return nil
	}, nil)
	defer session.close(context.Canceled)

	first := message{ID: "first", Type: "request", Method: "process_list"}
	if !session.startRequest(first, nil) {
		t.Fatal("first request was not admitted")
	}

	select {
	case admitted := <-secondAdmission:
		if !admitted {
			t.Fatal("reply became visible before its request admission was released")
		}
	case <-time.After(time.Second):
		t.Fatal("first request did not reply")
	}

	seen := map[string]bool{}
	for len(seen) < 2 {
		select {
		case reply := <-replies:
			if reply.Type != "response" {
				t.Fatalf("reply = %#v", reply)
			}
			seen[reply.ID] = true
		case <-time.After(time.Second):
			t.Fatalf("replies = %v", seen)
		}
	}
	waitForCondition(t, "request admission drain", func() bool { return len(c.requestSlots) == 0 })
}

func TestRuntimeAuthLoginStartRebindsRunningButDoesNotReplayCompletedCeremony(t *testing.T) {
	c, err := newConnector(config{name: "test", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeExternalRuntimes)

	oldReplies := make(chan message, 1)
	old := c.claimConnection(context.Background(), func(_ context.Context, reply message) error {
		oldReplies <- reply
		return nil
	}, nil)
	request := message{
		ID: "runtime-auth-start", Type: "request", Method: "runtime_auth_login_start",
		Params: map[string]any{
			"provider": "codex", "identity_material": "/usr/bin/codex", "flow": "device_code",
		},
	}
	fingerprint, err := requestFingerprint(request)
	if err != nil {
		t.Fatal(err)
	}
	if binding, _ := c.bindRequestOperation(old, request, fingerprint); binding != requestExecute {
		t.Fatalf("initial binding = %v, want execute", binding)
	}

	replacementReplies := make(chan message, 1)
	replacement := c.claimConnection(context.Background(), func(_ context.Context, reply message) error {
		replacementReplies <- reply
		return nil
	}, nil)
	defer replacement.close(context.Canceled)
	if binding, _ := c.bindRequestOperation(replacement, request, fingerprint); binding != requestRebound {
		t.Fatalf("in-flight replacement binding = %v, want rebound", binding)
	}

	ceremony := message{ID: request.ID, Type: "response", Result: map[string]any{
		"attempt_id":       "attempt-secret",
		"verification_url": "https://auth.openai.com/codex/device",
		"user_code":        "SECRET-CODE",
	}}
	c.completeRequestOperation(request.ID, request.Method, ceremony, nil)
	<-c.requestSlots
	select {
	case reply := <-replacementReplies:
		result, _ := reply.Result.(map[string]any)
		if stringParam(result, "user_code") != "SECRET-CODE" {
			t.Fatalf("replacement reply = %#v", reply)
		}
	case <-time.After(time.Second):
		t.Fatal("replacement did not receive the in-flight ceremony")
	}
	select {
	case reply := <-oldReplies:
		t.Fatalf("old reply sink received rebound ceremony: %#v", reply)
	default:
	}

	c.requestMu.Lock()
	completed := c.requestOperations[request.ID]
	c.requestMu.Unlock()
	if completed == nil || !completed.done || completed.replayCompleted || completed.reply.Result != nil || completed.replyBytes != 0 {
		t.Fatalf("completed sensitive operation retained ceremony: %#v", completed)
	}

	if binding, _ := c.bindRequestOperation(replacement, request, fingerprint); binding != requestExecute {
		t.Fatalf("completed sensitive retry binding = %v, want fresh execution", binding)
	}
	<-c.requestSlots
	c.requestMu.Lock()
	delete(c.requestOperations, request.ID)
	c.requestMu.Unlock()
}

func TestConnectionLocalRequestsAreNeverReplayCached(t *testing.T) {
	for _, method := range []string{"android", "read_stream", "write_stream", "meeting_artifact_read"} {
		if recoverableRequest(message{ID: "stable", Method: method}) {
			t.Fatalf("%s must not rebind or replay across connector sessions", method)
		}
	}
	if !recoverableRequest(message{ID: "stable", Method: "stat"}) {
		t.Fatal("ordinary bounded requests should remain recoverable")
	}
}
