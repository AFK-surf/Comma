package main

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

type blockingWriteCloser struct {
	started chan struct{}
	closed  chan struct{}
	once    sync.Once
}

func newBlockingWriteCloser() *blockingWriteCloser {
	return &blockingWriteCloser{started: make(chan struct{}), closed: make(chan struct{})}
}

func (f *blockingWriteCloser) Write(data []byte) (int, error) {
	close(f.started)
	<-f.closed
	return 0, errors.New("closed during write")
}

func (f *blockingWriteCloser) Close() error {
	f.once.Do(func() { close(f.closed) })
	return nil
}

func TestConnectionReplacementDetachesBlockedWriteAndServesNewRequests(t *testing.T) {
	c, err := newConnector(config{name: "test", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	old := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, func(error) {})
	file := newBlockingWriteCloser()
	pending, err := old.reservePendingWrite("write-1")
	if err != nil || !old.activatePendingWrite("write-1", pending, file) {
		t.Fatalf("prepare blocked write: %v", err)
	}
	if !old.startStream(message{
		ID:   "write-1",
		Type: "stream",
		Stream: &streamData{
			Channel: "data",
			Data:    base64.StdEncoding.EncodeToString([]byte("payload")),
		},
	}, nil) {
		t.Fatal("old stream was not admitted")
	}
	select {
	case <-file.started:
	case <-time.After(time.Second):
		t.Fatal("old stream did not block in Write")
	}

	responses := make(chan message, 1)
	newSession := c.claimConnection(context.Background(), func(_ context.Context, m message) error {
		responses <- m
		return nil
	}, func(error) {})
	defer newSession.close(context.Canceled)
	if !newSession.startRequest(message{ID: "new-1", Type: "request", Method: "process_list"}, nil) {
		t.Fatal("replacement connection did not admit a request")
	}
	select {
	case response := <-responses:
		if response.Type != "response" || response.ID != "new-1" {
			t.Fatalf("replacement response = %#v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked old stream delayed replacement request")
	}
	if !old.wait() {
		t.Fatal("old connection worker did not drain after file cleanup")
	}
}

func TestOldConnectionCleanupCannotRemoveNewConnectionTransfer(t *testing.T) {
	c, err := newConnector(config{name: "test", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	old := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, func(error) {})
	newSession := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, func(error) {})
	defer newSession.close(context.Canceled)

	pending, err := newSession.reservePendingWrite("same-id")
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(filepath.Join(t.TempDir(), "new-generation"))
	if err != nil {
		t.Fatal(err)
	}
	if !newSession.activatePendingWrite("same-id", pending, file) {
		t.Fatal("failed to activate new-generation transfer")
	}

	old.abortPendingTransfers("late old cleanup")
	if got := newSession.pendingWrite("same-id"); got != pending {
		t.Fatal("old connection cleanup removed new connection transfer")
	}
	if c.setIdentity(old, "old-run", "old-device", "old-connector", "old-owner", 1) {
		t.Fatal("replaced connection updated connector identity")
	}
	if !c.setIdentity(newSession, "new-run", "new-device", "new-connector", "new-owner", 2) {
		t.Fatal("active connection could not update connector identity")
	}
	if runID, deviceID, connectorID := c.connectionIdentity(); runID != "new-run" || deviceID != "new-device" || connectorID != "new-connector" {
		t.Fatalf("connection identity = %q %q %q", runID, deviceID, connectorID)
	}
}

func TestPrepareWriteStreamReservesCapacityBeforeTruncating(t *testing.T) {
	root := t.TempDir()
	c, err := newConnector(config{name: "test", root: root})
	if err != nil {
		t.Fatal(err)
	}
	session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, nil)
	defer session.close(context.Canceled)
	for i := 0; i < maxPendingWriteStreams; i++ {
		if _, err := session.reservePendingWrite(string(rune('a' + i))); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(root, "important.txt")
	if err := os.WriteFile(path, []byte("keep me"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := c.prepareWriteStream(context.Background(), session, "overflow", map[string]any{"path": "important.txt"}); err == nil {
		t.Fatal("capacity-exhausted write stream succeeded")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "keep me" {
		t.Fatalf("rejected write truncated content: %q", content)
	}
}

func TestCloseSealsWorkerAdmissionBeforeWaiting(t *testing.T) {
	c, err := newConnector(config{name: "test", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	for iteration := 0; iteration < 100; iteration++ {
		session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, nil)
		start := make(chan struct{})
		var starters sync.WaitGroup
		for worker := 0; worker < 16; worker++ {
			starters.Add(1)
			go func() {
				defer starters.Done()
				<-start
				for request := 0; request < 16; request++ {
					session.startRequest(message{ID: "race", Type: "request", Method: "process_list"}, nil)
				}
			}()
		}
		close(start)
		session.close(context.Canceled)
		starters.Wait()
		if !session.wait() {
			t.Fatal("workers admitted after session close")
		}
		if session.startRequest(message{ID: "late", Type: "request", Method: "process_list"}, nil) {
			t.Fatal("closed session admitted a late worker")
		}
	}
}

func TestBlockedFilesystemRequestDeadlineDoesNotOwnTransport(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "blocking-fifo")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := newConnector(config{name: "test", root: root})
	if err != nil {
		t.Fatal(err)
	}
	closed := make(chan error, 1)
	responses := make(chan message, 1)
	session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, func(err error) {
		select {
		case closed <- err:
		default:
		}
	})
	session.sendCtx = func(_ context.Context, msg message) error {
		responses <- msg
		return nil
	}
	session.deadline = func(message) time.Duration { return 20 * time.Millisecond }
	if !session.startRequest(message{ID: "blocked-read", Type: "request", Method: "read", Params: map[string]any{"path": path}}, nil) {
		t.Fatal("blocked read was not admitted")
	}
	time.Sleep(50 * time.Millisecond)
	select {
	case err := <-closed:
		t.Fatalf("request deadline closed transport: %v", err)
	default:
	}

	writer, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("released")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case response := <-responses:
		if response.ID != "blocked-read" || response.Type != "response" {
			t.Fatalf("response = %#v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("released filesystem request did not finish")
	}
}

func TestRequestTimeoutHonorsLongRunningMethodContracts(t *testing.T) {
	tests := []struct {
		name string
		msg  message
		want time.Duration
	}{
		{name: "exec floor", msg: message{Method: "exec", Params: map[string]any{"timeout": 5}}, want: 2 * time.Minute},
		{name: "long exec", msg: message{Method: "exec", Params: map[string]any{"timeout": 600}}, want: 605 * time.Second},
		{name: "http", msg: message{Method: "http_request", Params: map[string]any{"timeout_seconds": 300}}, want: 305 * time.Second},
		{name: "tail", msg: message{Method: "process_tail", Params: map[string]any{"wait_seconds": 200}}, want: 205 * time.Second},
		{name: "runtime probe", msg: message{Method: "runtime_probe"}, want: 30 * time.Second},
		{name: "local file read", msg: message{Method: "read_ref"}, want: time.Minute},
		{name: "meeting artifact missing size", msg: message{Method: "meeting_artifact_read"}, want: 2 * time.Minute},
		{name: "meeting artifact small", msg: message{Method: "meeting_artifact_read", Params: map[string]any{"expected_size": int64(64 * 1024)}}, want: 2 * time.Minute},
		{name: "meeting artifact maximum", msg: message{Method: "meeting_artifact_read", Params: map[string]any{"expected_size": int64(30 * 1024 * 1024)}}, want: 3 * time.Minute},
		{name: "meeting artifact malformed", msg: message{Method: "meeting_artifact_read", Params: map[string]any{"expected_size": "huge"}}, want: 2 * time.Minute},
		{name: "meeting artifact oversize", msg: message{Method: "meeting_artifact_read", Params: map[string]any{"expected_size": int64(1 << 62)}}, want: 2 * time.Minute},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := requestTimeout(tt.msg); got != tt.want {
				t.Fatalf("requestTimeout() = %s, want %s", got, tt.want)
			}
		})
	}
}

func TestCleanupQueueExhaustionIsTerminalForRemoteAndVM(t *testing.T) {
	c := &connector{
		cleanupQueue: make(chan io.Closer, 1),
		fatalErrors:  make(chan error, 1),
		fatalSignal:  make(chan struct{}),
	}
	c.enqueueCleanup(io.NopCloser(&zeroReader{}))
	c.enqueueCleanup(io.NopCloser(&zeroReader{}))
	select {
	case err := <-c.fatalErrors:
		if !isConnectorFatal(err) || !terminalConnectionError(err) {
			t.Fatalf("cleanup exhaustion was not terminal: %T %v", err, err)
		}
	case <-time.After(time.Second):
		t.Fatal("cleanup exhaustion did not report a fatal error")
	}
}

type zeroReader struct{}

func (*zeroReader) Read([]byte) (int, error) { return 0, io.EOF }

type gatedProcessStdin struct {
	entered chan struct{}
	release chan struct{}

	mu        sync.Mutex
	active    int
	maxActive int
	deadline  time.Time
	unblock   sync.Once
}

func newGatedProcessStdin() *gatedProcessStdin {
	return &gatedProcessStdin{entered: make(chan struct{}, 2), release: make(chan struct{})}
}

func (s *gatedProcessStdin) Write(data []byte) (int, error) {
	s.mu.Lock()
	s.active++
	if s.active > s.maxActive {
		s.maxActive = s.active
	}
	s.mu.Unlock()
	s.entered <- struct{}{}
	<-s.release
	s.mu.Lock()
	s.active--
	s.mu.Unlock()
	return len(data), nil
}

func (*gatedProcessStdin) Close() error { return nil }

func (s *gatedProcessStdin) SetWriteDeadline(deadline time.Time) error {
	s.mu.Lock()
	s.deadline = deadline
	s.mu.Unlock()
	if !deadline.IsZero() && !deadline.After(time.Now()) {
		s.unblock.Do(func() { close(s.release) })
	}
	return nil
}

func (s *gatedProcessStdin) snapshot() (int, time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.maxActive, s.deadline
}

func TestProcessWritesAreSerializedPerProcess(t *testing.T) {
	stdin := newGatedProcessStdin()
	proc := &managedProcess{name: "serial", stdin: stdin, stdinSlot: make(chan struct{}, 1), status: "running"}
	c := &connector{processes: map[string]*managedProcess{"serial": proc}}
	results := make(chan error, 2)
	write := func(data string) {
		_, err := c.methodProcessWrite(context.Background(), map[string]any{"process_name": "serial", "data": data})
		results <- err
	}
	go write("first")
	<-stdin.entered
	go write("second")
	select {
	case <-stdin.entered:
		t.Fatal("second stdin write entered before the first completed")
	case <-time.After(20 * time.Millisecond):
	}
	stdin.release <- struct{}{}
	select {
	case <-stdin.entered:
	case <-time.After(time.Second):
		t.Fatal("second stdin write did not run after the first")
	}
	stdin.release <- struct{}{}
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	maxActive, deadline := stdin.snapshot()
	if maxActive != 1 || !deadline.IsZero() {
		t.Fatalf("stdin state max_active=%d deadline=%v", maxActive, deadline)
	}
}

func TestCancelledProcessWriteCannotRestoreAnExpiredDeadline(t *testing.T) {
	stdin := newGatedProcessStdin()
	proc := &managedProcess{name: "cancel", stdin: stdin, stdinSlot: make(chan struct{}, 1), status: "running"}
	c := &connector{processes: map[string]*managedProcess{"cancel": proc}}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := c.methodProcessWrite(ctx, map[string]any{"process_name": "cancel", "data": "blocked"})
		result <- err
	}()
	<-stdin.entered
	cancel()
	select {
	case <-result:
	case <-time.After(time.Second):
		t.Fatal("cancelled process write did not return")
	}
	time.Sleep(20 * time.Millisecond)
	_, deadline := stdin.snapshot()
	if !deadline.IsZero() {
		t.Fatalf("cancellation watcher changed deadline after cleanup: %v", deadline)
	}
}
