package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"testing/synctest"
	"time"
)

func TestRuntimeExecutionCorrelatesConcurrentRequestsAtSameTime(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := &connector{}
		requests := make(chan message, 2)
		transport := &runtimeTransport{done: make(chan struct{})}
		transport.send = func(_ context.Context, request message) error {
			requests <- request
			return nil
		}
		c.activeTransport = transport
		results := make(chan error, 2)
		// The bubble holds time fixed while both requests enter the transport.
		for caller := range 2 {
			go func() {
				result, err := c.runtimeExecution(context.Background(), "list", "", map[string]any{"caller": caller})
				if err == nil && result["caller"] != caller {
					err = fmt.Errorf("caller %d received another caller's response: %v", caller, result)
				}
				results <- err
			}()
		}
		first, second := <-requests, <-requests
		for _, request := range []message{second, first} {
			c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: request.Params["target"]})
		}
		for range 2 {
			if err := <-results; err != nil {
				t.Errorf("concurrent request lost its response: %v", err)
			}
		}
	})
}

func TestRuntimeExecutionQueuesAtSocketCapacity(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	started := make(chan message, 8)
	finish := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(finish) }) }
	defer unblock()
	transport := &runtimeTransport{done: make(chan struct{})}
	transport.send = func(_ context.Context, request message) error {
		started <- request
		go func() {
			<-finish
			c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{}})
		}()
		return nil
	}
	c.activeTransport = transport
	results := make(chan error, 6)
	for range 6 {
		go func() {
			_, err := c.runtimeExecution(context.Background(), "list", "", c.currentComputeRuntimeExecutionTarget())
			results <- err
		}()
	}
	for range 2 {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("requests did not reach transport")
		}
	}
	select {
	case <-started:
		t.Fatal("health requests exceeded socket control capacity")
	case <-time.After(50 * time.Millisecond):
	}
	// The control queue must not consume the separate operation allowance.
	go func() {
		_, _ = c.runtimeExecution(context.Background(), "acquire", "auth-independent", c.currentComputeRuntimeExecutionTarget())
	}()
	select {
	case request := <-started:
		if request.Params["action"] != "acquire" {
			t.Fatal("queued control request bypassed capacity")
		}
	case <-time.After(time.Second):
		t.Fatal("control requests blocked operation admission")
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.runtimeExecution(cancelled, "list", "", c.currentComputeRuntimeExecutionTarget()); err == nil {
		t.Fatal("cancelled queued request succeeded")
	}
	unblock()
	for range 6 {
		select {
		case err := <-results:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("queued request did not resume")
		}
	}
}
