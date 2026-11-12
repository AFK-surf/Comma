package main

import (
	"context"
	proxy "github.com/comma/salix-account-proxy"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy"
	logrus "github.com/sirupsen/logrus"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	// stdout belongs exclusively to the framed protocol.
	log.SetOutput(os.Stderr)
	logrus.SetOutput(os.Stderr)
	logrus.SetFormatter(&logrus.JSONFormatter{})
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	// Grok chat-proxy refuses an outdated client version with HTTP 426.
	cliproxy.StartXAIVersionUpdater(ctx)
	go func() { <-ctx.Done(); _ = os.Stdin.Close() }()
	if err := proxy.Run(ctx, os.Stdin, os.Stdout); err != nil && ctx.Err() == nil {
		log.Fatal(err)
	}
}
