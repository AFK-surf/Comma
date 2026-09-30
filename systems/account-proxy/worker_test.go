package accountproxy

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type wireClient struct {
	in     *io.PipeWriter
	events chan event
}

func wire(t *testing.T, invoke operation) *wireClient {
	t.Helper()
	input, writer := io.Pipe()
	reader, output := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	c := &wireClient{in: writer, events: make(chan event, 128)}
	go func() { _ = run(ctx, input, output, invoke); _ = output.Close() }()
	go func() {
		defer close(c.events)
		for {
			data, err := readFrame(reader)
			if err != nil {
				return
			}
			var e event
			if json.Unmarshal(data, &e) != nil {
				return
			}
			c.events <- e
		}
	}()
	t.Cleanup(func() { cancel(); _ = writer.Close(); _ = reader.Close(); _ = input.Close() })
	return c
}
func (c *wireClient) send(t *testing.T, id, kind, op string) {
	t.Helper()
	data, _ := json.Marshal(command{ID: id, Type: kind, Op: op, Body: json.RawMessage(`{}`)})
	if err := writeFrame(c.in, data); err != nil {
		t.Fatal(err)
	}
}
func (c *wireClient) next(t *testing.T) event {
	t.Helper()
	select {
	case e, ok := <-c.events:
		if !ok {
			t.Fatal("worker exited")
		}
		return e
	case <-time.After(3 * time.Second):
		t.Fatal("worker did not respond")
		return event{}
	}
}
func TestWireSlowConsumerAndCancellationDoNotBlockAnotherCall(t *testing.T) {
	cancelled := make(chan struct{})
	c := wire(t, func(ctx context.Context, op string, _ json.RawMessage, _ Credential, emit emitter) error {
		if op == "slow" {
			defer close(cancelled)
			return emit([]byte(strings.Repeat("s", chunkSize*2)))
		}
		return emit([]byte("fast"))
	})
	c.send(t, "slow", "call", "slow")
	first := c.next(t)
	if first.ID != "slow" || len(first.Data) != chunkSize {
		t.Fatal(first)
	}
	// No acknowledgement for slow: another request still completes.
	c.send(t, "fast", "call", "fast")
	second := c.next(t)
	if second.ID != "fast" || string(second.Data) != "fast" {
		t.Fatal(second)
	}
	c.send(t, "fast", "ack", "")
	if done := c.next(t); done.ID != "fast" || done.Type != "done" {
		t.Fatal(done)
	}
	c.send(t, "slow", "cancel", "")
	if result := c.next(t); result.ID != "slow" || result.Status != 499 {
		t.Fatal(result)
	}
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("upstream was not cancelled")
	}
}
func TestWireAcknowledgedFramesReassembleExactly(t *testing.T) {
	payload := strings.Repeat("中文\n", chunkSize)
	c := wire(t, func(_ context.Context, _ string, _ json.RawMessage, _ Credential, emit emitter) error {
		return emit([]byte(payload))
	})
	c.send(t, "one", "call", "echo")
	var got strings.Builder
	for {
		e := c.next(t)
		if e.Type == "done" {
			break
		}
		if e.Type != "data" || len(e.Data) > chunkSize {
			t.Fatal(e)
		}
		got.Write(e.Data)
		c.send(t, "one", "ack", "")
	}
	if got.String() != payload {
		t.Fatal("framing lost or reordered bytes")
	}
}
func TestWireAdmissionIsBounded(t *testing.T) {
	c := wire(t, func(ctx context.Context, _ string, _ json.RawMessage, _ Credential, _ emitter) error {
		<-ctx.Done()
		return ctx.Err()
	})
	for i := 0; i < maxCalls+1; i++ {
		c.send(t, string(rune('a'+i)), "call", "hold")
	}
	if e := c.next(t); e.Type != "error" || e.Status != 429 {
		t.Fatal(e)
	}
}
func TestWireParentDeathCancelsUpstream(t *testing.T) {
	started, cancelled := make(chan struct{}), make(chan struct{})
	c := wire(t, func(ctx context.Context, _ string, _ json.RawMessage, _ Credential, _ emitter) error {
		close(started)
		<-ctx.Done()
		close(cancelled)
		return ctx.Err()
	})
	c.send(t, "one", "call", "hold")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("not started")
	}
	_ = c.in.Close()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("orphan upstream call")
	}
}

// This child runs the real framed worker and native executors against the
// Elixir integration test's synthetic upstream, without a listening adapter.
func TestWorkerProcess(t *testing.T) {
	upstream := os.Getenv("SALIX_SUBSCRIPTION_TEST_UPSTREAM")
	if upstream == "" {
		t.Skip("subprocess fixture")
	}
	u, err := url.Parse(upstream)
	if err != nil {
		os.Exit(2)
	}
	rt := &rewriteTransport{url: u, handler: http.DefaultTransport}
	http.DefaultTransport = rt
	ctx := context.WithValue(context.Background(), "cliproxy.roundtripper", rt)
	if Run(ctx, os.Stdin, os.Stdout) != nil {
		os.Exit(2)
	}
	os.Exit(0)
}

// This fixture exercises the real Port protocol without provider accounts.
func TestWorkerBudgetProcess(t *testing.T) {
	if os.Getenv("SALIX_WORKER_BUDGET_TEST") != "1" {
		t.Skip("subprocess fixture")
	}
	invoke := func(ctx context.Context, _ string, body json.RawMessage, _ Credential, emit emitter) error {
		var request struct {
			Delay   int    `json:"delay"`
			Gap     int    `json:"gap"`
			Padding string `json:"padding"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			return err
		}
		for i, ms := range []int{request.Delay, request.Gap} {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(ms) * time.Millisecond):
			}
			payload := "first"
			if i == 1 {
				payload = "last"
			}
			if err := emit([]byte(payload)); err != nil {
				return err
			}
		}
		return nil
	}
	if run(context.Background(), os.Stdin, os.Stdout, invoke) != nil {
		os.Exit(2)
	}
	os.Exit(0)
}

func TestRequestFrameBoundary(t *testing.T) {
	for _, size := range []int{4 * 1024 * 1024, 16 * 1024 * 1024} {
		var wire bytes.Buffer
		payload := bytes.Repeat([]byte("a"), size)
		if err := writeFrame(&wire, payload); err != nil {
			t.Fatal(err)
		}
		got, err := readFrame(&wire)
		if err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("%d-byte request: %v", size, err)
		}
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], 16*1024*1024+1)
	if _, err := readFrame(bytes.NewReader(header[:])); err == nil {
		t.Fatal("oversized header accepted")
	}
}

func TestWireByteBudgetRetainsCancelledExecutors(t *testing.T) {
	started := make(chan string, 16)
	cancelled := make(chan struct{})
	release := make(chan struct{})
	releaseFirst := make(chan struct{})
	unblockFirst := sync.OnceFunc(func() { close(releaseFirst) })
	t.Cleanup(unblockFirst)
	t.Cleanup(func() { close(release) })
	c := wire(t, func(ctx context.Context, op string, _ json.RawMessage, _ Credential, emit emitter) error {
		if op == "small" {
			return emit([]byte("ok"))
		}
		started <- op
		<-ctx.Done()
		if op == "hold0" {
			close(cancelled)
			<-releaseFirst
		} else {
			<-release
		}
		return ctx.Err()
	})
	// Twelve almost-full frames leave space for small requests, not a thirteenth large one.
	body := json.RawMessage(`{"padding":"` + strings.Repeat("x", 16*1024*1024-4096) + `"}`)
	sendLarge := func(id string) {
		t.Helper()
		data, err := json.Marshal(command{ID: id, Type: "call", Op: id, Body: body})
		if err != nil {
			t.Fatal(err)
		}
		if err := writeFrame(c.in, data); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 12; i++ {
		id := fmt.Sprintf("hold%d", i)
		sendLarge(id)
		select {
		case got := <-started:
			if got != id {
				t.Fatal(got)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("call not admitted")
		}
	}
	sendLarge("full")
	if e := c.next(t); e.ID != "full" || e.Code != "worker_busy" {
		t.Fatal(e)
	}
	c.send(t, "small", "call", "small")
	if e := c.next(t); e.ID != "small" || string(e.Data) != "ok" {
		t.Fatal(e)
	}
	c.send(t, "small", "ack", "")
	if e := c.next(t); e.ID != "small" || e.Type != "done" {
		t.Fatal(e)
	}
	c.send(t, "hold0", "cancel", "")
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("cancel not delivered")
	}
	sendLarge("still-full")
	if e := c.next(t); e.ID != "still-full" || e.Code != "worker_busy" {
		t.Fatal(e)
	}
	unblockFirst()
	if e := c.next(t); e.ID != "hold0" || e.Status != 499 {
		t.Fatal(e)
	}
	// A terminal write can precede the deferred capacity release by one scheduling turn.
	for attempt := 0; attempt < 20; attempt++ {
		data, _ := json.Marshal(command{ID: "recovered", Type: "call", Op: "small", Body: body})
		if err := writeFrame(c.in, data); err != nil {
			t.Fatal(err)
		}
		e := c.next(t)
		if e.Code == "worker_busy" {
			time.Sleep(time.Millisecond)
			continue
		}
		if e.ID != "recovered" || string(e.Data) != "ok" {
			t.Fatal(e)
		}
		c.send(t, "recovered", "ack", "")
		if done := c.next(t); done.ID != "recovered" || done.Type != "done" {
			t.Fatal(done)
		}
		return
	}
	t.Fatal("completed cancellation did not restore byte capacity")
}
