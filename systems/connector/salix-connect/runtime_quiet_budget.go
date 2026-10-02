package main

import (
	"context"
	"sync"
	"time"
)

const cloudRuntimeQuietTimeout = 90 * time.Second
const nativeQuietConcurrency = 4

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

// Callers provide one bounded Session page and hold its admission fences.
// Join all checks before those fences are released, including after failure.
func checkNativeQuietPage[T any](ctx context.Context, page []T, check func(context.Context, T) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan T, len(page))
	for _, item := range page {
		jobs <- item
	}
	close(jobs)
	var workers sync.WaitGroup
	var first sync.Once
	var failure error
	for range min(nativeQuietConcurrency, len(page)) {
		workers.Go(func() {
			for item := range jobs {
				if ctx.Err() != nil {
					return
				}
				if err := check(ctx, item); err != nil {
					first.Do(func() { failure = err; cancel() })
					return
				}
			}
		})
	}
	workers.Wait()
	if failure != nil {
		return failure
	}
	return ctx.Err()
}
