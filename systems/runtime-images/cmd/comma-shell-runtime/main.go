package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

// comma-shell-runtime is PID 1 for the shell image. Agent VMM owns process
// execution through its guest API; the supervisor only keeps the container
// alive and gives it deterministic signal semantics.
func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	if ctx == nil {
		return errors.New("shell runtime requires a context")
	}
	<-ctx.Done()
	return nil
}
