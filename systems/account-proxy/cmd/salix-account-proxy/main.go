package main

import (
	"context"
	proxy "github.com/comma/salix-account-proxy"
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
	go func() { <-ctx.Done(); _ = os.Stdin.Close() }()
	if err := proxy.Run(ctx, os.Stdin, os.Stdout); err != nil && ctx.Err() == nil {
		log.Fatal(err)
	}
}
