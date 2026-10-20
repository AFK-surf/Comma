package main

import (
	"context"
	"net"
	"net/http"
	"sync"
	"testing"
)

// memoryServer serves handler over in-memory pipes instead of sockets. It
// returns the Server URL and the dial function to put in the connector's
// config. A write that the server does not read blocks for good, as it would
// once every network buffer is full, and in a synctest bubble the blocked side
// waits durably, so the bubble's clock reaches the deadline the test is about.
func memoryServer(t *testing.T, handler http.Handler) (string, func(context.Context, string, string) (net.Conn, error)) {
	t.Helper()
	listener := &memoryListener{conns: make(chan net.Conn), closed: make(chan struct{})}
	server := &http.Server{Handler: handler}
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = server.Serve(listener)
	}()
	t.Cleanup(func() {
		_ = server.Close()
		<-served
	})
	dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
		client, peer := net.Pipe()
		select {
		case listener.conns <- peer:
			return client, nil
		case <-listener.closed:
			return nil, net.ErrClosed
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return "http://server.test", dial
}

type memoryListener struct {
	conns  chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func (l *memoryListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *memoryListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *memoryListener) Addr() net.Addr { return memoryAddr{} }

type memoryAddr struct{}

func (memoryAddr) Network() string { return "memory" }
func (memoryAddr) String() string  { return "server.test" }
