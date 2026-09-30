package main

import (
	"context"
	"errors"
	"io"
	"os"
	"sync"
	"testing"
	"time"
)

type gatedJSONWriter struct {
	started chan message
	permit  chan struct{}
	closed  chan struct{}
	once    sync.Once
}

func newGatedJSONWriter() *gatedJSONWriter {
	return &gatedJSONWriter{
		started: make(chan message, 8),
		permit:  make(chan struct{}, 8),
		closed:  make(chan struct{}),
	}
}

func (w *gatedJSONWriter) WriteJSON(value any) error {
	w.started <- value.(message)
	select {
	case <-w.permit:
		return nil
	case <-w.closed:
		return errors.New("test writer closed")
	}
}

func (w *gatedJSONWriter) SetWriteDeadline(time.Time) error { return nil }

func (w *gatedJSONWriter) Close() error {
	w.once.Do(func() { close(w.closed) })
	return nil
}

func TestWebSocketWriterPrioritizesControlFrames(t *testing.T) {
	conn := newGatedJSONWriter()
	writer := newWebSocketWriter(conn)
	defer writer.Close(nil)

	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.SendContext(context.Background(), message{ID: "data-1", Type: "response"})
	}()

	if got := receiveStartedWrite(t, conn); got.ID != "data-1" {
		t.Fatalf("first write = %#v", got)
	}
	if err := writer.Enqueue(message{ID: "data-2", Type: "response"}); err != nil {
		t.Fatalf("enqueue data: %v", err)
	}
	if err := writer.Enqueue(message{Type: "heartbeat"}); err != nil {
		t.Fatalf("enqueue heartbeat: %v", err)
	}

	conn.permit <- struct{}{}
	if err := <-firstDone; err != nil {
		t.Fatalf("first send: %v", err)
	}
	if got := receiveStartedWrite(t, conn); got.Type != "heartbeat" {
		t.Fatalf("second write = %#v, want heartbeat", got)
	}
	conn.permit <- struct{}{}
	if got := receiveStartedWrite(t, conn); got.ID != "data-2" {
		t.Fatalf("third write = %#v, want queued data", got)
	}
	conn.permit <- struct{}{}
}

func TestWebSocketWriterCloseReleasesBlockedSend(t *testing.T) {
	conn := newGatedJSONWriter()
	writer := newWebSocketWriter(conn)
	done := make(chan error, 1)
	go func() {
		done <- writer.SendContext(context.Background(), message{ID: "blocked", Type: "response"})
	}()
	_ = receiveStartedWrite(t, conn)

	writer.Close(errors.New("connection cancelled"))
	if err := writer.Enqueue(message{Type: "heartbeat"}); err == nil {
		t.Fatal("enqueue succeeded after writer close")
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("blocked send returned nil error")
		}
	case <-time.After(time.Second):
		t.Fatal("blocked send was not released by close")
	}
}

func TestWebSocketWriterSendContextDoesNotWaitBehindFullQueue(t *testing.T) {
	conn := newGatedJSONWriter()
	writer := newWebSocketWriter(conn)
	defer writer.Close(nil)
	go func() { _ = writer.SendContext(context.Background(), message{ID: "active", Type: "response"}) }()
	_ = receiveStartedWrite(t, conn)
	for i := 0; i < webSocketDataQueueSize; i++ {
		if err := writer.Enqueue(message{ID: "queued", Type: "response"}); err != nil {
			t.Fatalf("fill queue %d: %v", i, err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- writer.SendContext(ctx, message{ID: "cancelled", Type: "response"}) }()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("SendContext error = %v, want context cancellation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("SendContext waited behind a full queue after cancellation")
	}
}

func TestWebSocketWriterRunsAdmissionReleaseBeforeWritingReply(t *testing.T) {
	conn := newGatedJSONWriter()
	writer := newWebSocketWriter(conn)
	defer writer.Close(nil)

	released := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- writer.SendContextBeforeWrite(
			context.Background(),
			message{ID: "reply", Type: "response"},
			func() { close(released) },
		)
	}()

	select {
	case <-released:
	case <-time.After(time.Second):
		t.Fatal("reply write started without releasing request admission")
	}
	if got := receiveStartedWrite(t, conn); got.ID != "reply" {
		t.Fatalf("write = %#v", got)
	}
	conn.permit <- struct{}{}
	if err := <-done; err != nil {
		t.Fatalf("send: %v", err)
	}
}

func TestAbortPendingTransfersClosesFilesAndACKWaiters(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "pending-write")
	if err != nil {
		t.Fatal(err)
	}
	ack := make(chan string, 1)
	c := &connector{
		cleanupQueue: make(chan io.Closer, cleanupQueueSize),
		fatalErrors:  make(chan error, 1),
	}
	go c.cleanupLoop()
	session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, nil)
	pending := &pendingWrite{}
	if !pending.setFile(f) {
		t.Fatal("failed to install pending file")
	}
	session.pendingWrites["write-1"] = pending
	session.pendingAcks["read-1:1"] = ack

	session.abortPendingTransfers("disconnected")

	if len(session.pendingWrites) != 0 || len(session.pendingAcks) != 0 {
		t.Fatalf("pending state not cleared: writes=%d acks=%d", len(session.pendingWrites), len(session.pendingAcks))
	}
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := f.Write([]byte("after close")); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("pending write file remained open")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case got := <-ack:
		if got != "disconnected" {
			t.Fatalf("ack error = %q", got)
		}
	default:
		t.Fatal("pending ACK waiter was not released")
	}
}

func TestReadStreamACKWaitHonorsConnectionCancellation(t *testing.T) {
	c := &connector{cleanupQueue: make(chan io.Closer, cleanupQueueSize), fatalErrors: make(chan error, 1)}
	session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- session.sendReadStreamFrame(
			ctx,
			"read-1",
			1,
			message{ID: "read-1", Type: "stream"},
		)
	}()

	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("ACK wait error = %v, want context cancellation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("ACK wait ignored connection cancellation")
	}
	if len(session.pendingAcks) != 0 {
		t.Fatalf("pending ACK map was not cleared: %d", len(session.pendingAcks))
	}
}

func TestReadStreamErrorACKReleasesWaiterImmediately(t *testing.T) {
	c := &connector{cleanupQueue: make(chan io.Closer, cleanupQueueSize), fatalErrors: make(chan error, 1)}
	var session *connectionSession
	session = newConnectionSession(c, context.Background(), func(_ context.Context, frame message) error {
		go session.completePendingAck(frame.ID, frame.Stream.Seq, "server stream consumer closed")
		return nil
	}, nil)

	started := time.Now()
	err := session.sendReadStreamFrame(
		context.Background(),
		"meeting-artifact",
		1,
		message{ID: "meeting-artifact", Type: "stream", Stream: &streamData{Seq: 1}},
	)
	if err == nil || err.Error() != "server stream consumer closed" {
		t.Fatalf("ACK error = %v, want server cancellation", err)
	}
	if elapsed := time.Since(started); elapsed >= time.Second {
		t.Fatalf("error ACK held the request waiter for %s", elapsed)
	}
	if len(session.pendingAcks) != 0 {
		t.Fatalf("pending ACK map was not cleared: %d", len(session.pendingAcks))
	}
}

func receiveStartedWrite(t *testing.T, conn *gatedJSONWriter) message {
	t.Helper()
	select {
	case msg := <-conn.started:
		return msg
	case <-time.After(time.Second):
		t.Fatal("writer did not start a write")
		return message{}
	}
}
