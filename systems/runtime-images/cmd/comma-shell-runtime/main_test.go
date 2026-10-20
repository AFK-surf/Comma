package main

import (
	"context"
	"testing"
	"testing/synctest"
)

func TestRunWaitsUntilCancellation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- run(ctx) }()

		// run is blocked once every goroutine of the bubble is.
		synctest.Wait()
		select {
		case err := <-done:
			t.Fatalf("run returned before cancellation: %v", err)
		default:
		}

		cancel()
		if err := <-done; err != nil {
			t.Fatalf("run returned error: %v", err)
		}
	})
}

func TestRunRejectsNilContext(t *testing.T) {
	if err := run(nil); err == nil {
		t.Fatal("run(nil) succeeded")
	}
}
