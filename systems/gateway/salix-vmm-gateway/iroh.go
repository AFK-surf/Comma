package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// irohProxy owns transport only. The destination Host authorizes each canonical
// ServiceRouteService request using its signed RouteCapability.
type irohProxy struct {
	socket   string
	ctx      context.Context
	slots    chan struct{}
	attempts atomic.Uint64
	failures atomic.Uint64
}

func startIroh(binary string) (*irohProxy, func(), error) {
	directory, err := os.MkdirTemp("", "salix-iroh-")
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	proxy := &irohProxy{socket: filepath.Join(directory, "dial.sock"), ctx: ctx, slots: make(chan struct{}, 64)}
	command := exec.CommandContext(ctx, binary, proxy.socket)
	command.Stderr = os.Stderr
	stdout, err := command.StdoutPipe()
	if err != nil {
		cancel()
		os.RemoveAll(directory)
		return nil, nil, err
	}
	if err := command.Start(); err != nil {
		cancel()
		os.RemoveAll(directory)
		return nil, nil, err
	}
	finished := make(chan struct{})
	go func() { _ = command.Wait(); cancel(); close(finished) }()
	var once sync.Once
	closeProxy := func() { once.Do(func() { cancel(); <-finished; os.RemoveAll(directory) }) }
	ready := make(chan bool, 1)
	go func() {
		reader := bufio.NewReader(stdout)
		line, err := reader.ReadString('\n')
		ready <- err == nil && line == "ready\n"
		_, _ = io.Copy(io.Discard, reader)
	}()
	select {
	case ok := <-ready:
		if ok {
			return proxy, closeProxy, nil
		}
	case <-time.After(20 * time.Second):
	case <-ctx.Done():
	}
	closeProxy()
	return nil, nil, errors.New("iroh dialer did not start")
}

func (p *irohProxy) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodConnect {
		http.Error(response, "CONNECT required", http.StatusMethodNotAllowed)
		return
	}
	// The listener enforces mTLS; this also prevents accidental exposure through
	// an unauthenticated listener if handler composition changes.
	if request.TLS == nil || len(request.TLS.VerifiedChains) == 0 {
		http.Error(response, "client certificate required", http.StatusUnauthorized)
		return
	}
	encoded := request.Header.Get("Iroh-Endpoint-Addr")
	if len(encoded) == 0 || len(encoded) > 11000 {
		http.Error(response, "invalid endpoint address", http.StatusBadRequest)
		return
	}
	address, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(address) > 8190 || !json.Valid(address) {
		http.Error(response, "invalid endpoint address", http.StatusBadRequest)
		return
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, address); err != nil {
		http.Error(response, "invalid endpoint address", http.StatusBadRequest)
		return
	}
	select {
	case <-p.ctx.Done():
		http.Error(response, "iroh unavailable", http.StatusServiceUnavailable)
		return
	default:
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	default:
		http.Error(response, "iroh capacity exhausted", http.StatusServiceUnavailable)
		return
	}
	dialer := net.Dialer{Timeout: 2 * time.Second}
	p.attempts.Add(1)
	connected := false
	defer func() {
		if !connected {
			p.failures.Add(1)
		}
	}()
	remote, err := dialer.DialContext(request.Context(), "unix", p.socket)
	if err != nil {
		http.Error(response, "iroh unavailable", http.StatusServiceUnavailable)
		return
	}
	defer remote.Close()
	stopRemote := context.AfterFunc(p.ctx, func() { remote.Close() })
	defer stopRemote()
	_ = remote.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err = remote.Write(append(compact.Bytes(), '\n')); err != nil {
		http.Error(response, "iroh unavailable", http.StatusBadGateway)
		return
	}
	reader := bufio.NewReader(remote)
	ready, err := reader.ReadString('\n')
	if err != nil || ready != "ready\n" {
		http.Error(response, "iroh connect failed", http.StatusBadGateway)
		return
	}
	hijacker, ok := response.(http.Hijacker)
	if !ok {
		http.Error(response, "HTTP/1.1 required", http.StatusHTTPVersionNotSupported)
		return
	}
	client, buffer, err := hijacker.Hijack()
	if err != nil {
		return
	}
	defer client.Close()
	stopClient := context.AfterFunc(p.ctx, func() { client.Close() })
	defer stopClient()
	deadline := time.Now().Add(time.Hour)
	_ = client.SetDeadline(deadline)
	_ = remote.SetDeadline(deadline)
	if _, err = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	if err = buffer.Flush(); err != nil {
		return
	}
	connected = true
	// Preserve bytes buffered with the CONNECT request or the worker handshake.
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(remote, buffer); done <- struct{}{} }()
	go func() { _, _ = io.Copy(client, reader); done <- struct{}{} }()
	<-done
	_ = client.Close()
	_ = remote.Close()
	<-done
}
