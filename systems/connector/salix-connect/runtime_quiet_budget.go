package main

import (
	"context"
	"time"
)

const cloudRuntimeQuietTimeout = 90 * time.Second

// Only waits for an existing owner. Cancellation does not transfer ownership.
func lockRuntimeContext(ctx context.Context, lock interface{ TryLock() bool }) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if lock.TryLock() {
			return nil
		}
		timer := time.NewTimer(10 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
