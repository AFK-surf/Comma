package main

import (
	"context"
	"testing"
	"time"
)

func TestRunWaitsUntilCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- run(ctx) }()

	select {
	case err := <-done:
		t.Fatalf("run returned before cancellation: %v", err)
	case <-time.After(10 * time.Millisecond):
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("run did not stop after cancellation")
	}
}

func TestRunRejectsNilContext(t *testing.T) {
	if err := run(nil); err == nil {
		t.Fatal("run(nil) succeeded")
	}
}
