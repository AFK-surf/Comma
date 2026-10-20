package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net"
	"testing"
)

type tunnelHarness struct {
	t       *testing.T
	session *connectionSession
	frames  chan message
	server  net.Conn
	result  map[string]any
}

// openTunnel dials a local listener through lan_tcp_dial and returns the
// accepted server side of the connection.
func openTunnel(t *testing.T) *tunnelHarness {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			accepted <- conn
		}
	}()

	frames := make(chan message, 256)
	c := &connector{}
	session := newConnectionSession(c, context.Background(), func(_ context.Context, m message) error {
		frames <- m
		return nil
	}, nil)
	t.Cleanup(func() { session.close(context.Canceled) })

	port := listener.Addr().(*net.TCPAddr).Port
	result, err := c.methodLANTCPDial(context.Background(), session, "t1", map[string]any{"host": "127.0.0.1", "port": port})
	if err != nil {
		t.Fatal(err)
	}
	var server net.Conn
	server = <-accepted
	t.Cleanup(func() { server.Close() })
	return &tunnelHarness{t: t, session: session, frames: frames, server: server, result: result}
}

func (h *tunnelHarness) next() message {
	h.t.Helper()
	m := <-h.frames
	if m.ID != "t1" || m.Type != "stream" || m.Stream == nil {
		h.t.Fatalf("frame = %+v", m)
	}
	return m
}

func (h *tunnelHarness) send(stream streamData) {
	if !h.session.routeTunnelFrame(message{ID: "t1", Type: "stream", Stream: &stream}) {
		h.t.Fatal("tunnel frame was not routed")
	}
}

func TestLANTCPDialRelaysBytesInBothDirections(t *testing.T) {
	h := openTunnel(t)
	if h.result["status"] != "connected" || h.result["window"] != lanTunnelWindow {
		t.Fatalf("result = %v", h.result)
	}

	if _, err := h.server.Write([]byte("SSH-2.0-test\r\n")); err != nil {
		t.Fatal(err)
	}
	if m := h.next(); m.Stream.Channel != lanTunnelChannel || m.Stream.Data != base64.StdEncoding.EncodeToString([]byte("SSH-2.0-test\r\n")) {
		t.Fatalf("data frame = %+v", m.Stream)
	}

	h.send(streamData{Channel: lanTunnelChannel, Data: base64.StdEncoding.EncodeToString([]byte("abc"))})
	h.send(streamData{Channel: lanTunnelChannel, Data: base64.StdEncoding.EncodeToString([]byte("de"))})
	got := make([]byte, 5)
	if _, err := io.ReadFull(h.server, got); err != nil || string(got) != "abcde" {
		t.Fatalf("server read %q, %v", got, err)
	}
	if m := h.next(); m.Stream.Channel != lanTunnelAckChannel || m.Stream.Seq != 3 {
		t.Fatalf("first ack = %+v", m.Stream)
	}
	if m := h.next(); m.Stream.Channel != lanTunnelAckChannel || m.Stream.Seq != 5 {
		t.Fatalf("second ack = %+v", m.Stream)
	}

	// The server closing its side ends the tunnel with an eof frame.
	h.server.Close()
	if m := h.next(); m.Stream.Channel != lanTunnelChannel || !m.Stream.EOF || m.Error != "" {
		t.Fatalf("eof frame = %+v error %q", m.Stream, m.Error)
	}
	if h.session.routeTunnelFrame(message{ID: "t1", Stream: &streamData{Channel: lanTunnelChannel, Data: "eA=="}}) != true {
		t.Fatal("late frame for a closed tunnel must still be consumed")
	}
}

func TestLANTCPDialStopsReadingAtAFullWindow(t *testing.T) {
	h := openTunnel(t)
	payload := bytes.Repeat([]byte("x"), 2*lanTunnelWindow)
	go h.server.Write(payload)

	received := 0
	for received < lanTunnelWindow {
		received += len(decode(t, h.next().Stream.Data))
	}
	if received != lanTunnelWindow {
		t.Fatalf("sent %d bytes before an ack, want exactly one window", received)
	}
	// The reader has sent its window and waits for an ack; it reads nothing
	// more until one comes.
	waitUntilParked(t, "select", "(*lanTunnel).waitWindow")
	select {
	case m := <-h.frames:
		t.Fatalf("frame beyond the window before an ack: %d bytes after %d", len(decode(t, m.Stream.Data)), received)
	default:
	}

	h.send(streamData{Channel: lanTunnelAckChannel, Seq: received})
	for received < len(payload) {
		received += len(decode(t, h.next().Stream.Data))
	}
}

func TestLANTCPDialClosesOnServerEOFAndRefusesOverflow(t *testing.T) {
	h := openTunnel(t)
	h.send(streamData{Channel: lanTunnelChannel, EOF: true})
	if _, err := h.server.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("server read after eof = %v", err)
	}

	h = openTunnel(t)
	// Stop the writer from draining so queued bytes reach the window.
	h.session.pendingMu.Lock()
	tunnel := h.session.tunnels["t1"]
	h.session.pendingMu.Unlock()
	tunnel.mu.Lock()
	tunnel.queued = lanTunnelWindow
	tunnel.mu.Unlock()
	h.send(streamData{Channel: lanTunnelChannel, Data: base64.StdEncoding.EncodeToString([]byte("y"))})
	if m := h.next(); !m.Stream.EOF || m.Error != "tunnel window exceeded" {
		t.Fatalf("overflow frame = %+v error %q", m.Stream, m.Error)
	}
}

func TestLANTCPDialEndsWithTheSocketAndRefusesBadPorts(t *testing.T) {
	h := openTunnel(t)
	h.session.close(context.Canceled)
	if _, err := h.server.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("server read after socket close = %v", err)
	}

	c := &connector{}
	session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, nil)
	defer session.close(context.Canceled)
	for _, port := range []any{0, 70000} {
		if _, err := c.methodLANTCPDial(context.Background(), session, "bad", map[string]any{"host": "127.0.0.1", "port": port}); err == nil {
			t.Fatalf("port %v accepted", port)
		}
	}
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	if _, err := c.methodLANTCPDial(context.Background(), session, "refused", map[string]any{"host": "127.0.0.1", "port": port}); err == nil {
		t.Fatal("closed port accepted")
	}
	if len(session.tunnels) != 0 {
		t.Fatalf("failed dials left tunnels: %v", session.tunnels)
	}
}

func decode(t *testing.T, data string) []byte {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(data)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
