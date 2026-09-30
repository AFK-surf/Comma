// Command comma-voice is the reference client for the comma.voice.v1 WebSocket
// voice API. See README.md.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		cancel()
		<-signals
		fmt.Fprintln(os.Stderr, "comma-voice: interrupted again, exiting")
		os.Exit(exitOther)
	}()
	os.Exit(run(ctx, os.Args[1:], env{lookup: os.LookupEnv}, stdio{in: os.Stdin, out: os.Stdout, err: os.Stderr}))
}
