package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"
)

// lan_tcp_dial opens one TCP connection from this gateway and relays its
// bytes over the connector socket, for ssh.open through a gateway device.
//
// The request answers once the connection is up. Both directions then use
// `stream` frames under the request id:
//
//	{"channel":"tcp","data":<base64>}  bytes, at most lanTunnelMaxFrame each
//	{"channel":"tcp","eof":true}       either side closed (with "error" on failure)
//	{"channel":"tcp_ack","seq":<n>}    the receiver has written n bytes in total
//
// A sender keeps at most lanTunnelWindow bytes unacknowledged, so neither side
// buffers more than one window per tunnel. A tunnel ends with its socket, with
// a scope downgrade, or when either side sends eof.
const (
	lanTunnelChannel     = "tcp"
	lanTunnelAckChannel  = "tcp_ack"
	lanTunnelMaxFrame    = 32 * 1024
	lanTunnelWindow      = 512 * 1024
	lanTunnelMaxOpen     = 8
	lanTunnelDialTimeout = 15 * time.Second
)

type lanTunnel struct {
	id      string
	conn    net.Conn
	ctx     context.Context
	cancel  context.CancelFunc
	session *connectionSession

	// Bytes from the server, in order. The window bounds what can queue here.
	incoming [][]byte
	queued   int64
	ready    chan struct{}

	mu      sync.Mutex
	changed chan struct{}
	sent    int64
	acked   int64
	closed  bool
	reason  string
}

func (c *connector) methodLANTCPDial(ctx context.Context, session *connectionSession, id string, params map[string]any) (map[string]any, error) {
	if session == nil {
		return nil, errors.New("lan_tcp_dial requires a connector socket")
	}
	host := stringParam(params, "host")
	if host == "" {
		return nil, errors.New("'host' is required")
	}
	port := intParam(params, "port", 0)
	if port < 1 || port > 65535 {
		return nil, errors.New("'port' must be between 1 and 65535")
	}
	timeout := time.Duration(intParam(params, "timeout_seconds", 0)) * time.Second
	if timeout <= 0 || timeout > lanTunnelDialTimeout {
		timeout = lanTunnelDialTimeout
	}

	// The tunnel outlives this request: it belongs to the socket and to the
	// command scope, not to the request deadline.
	tunnelCtx, cancel, admitted := c.commandAdmissionContext(session.ctx)
	if !admitted {
		return nil, fmt.Errorf("method %q is not permitted for a %s connector", "lan_tcp_dial", scopeLocalFileRead)
	}
	tunnel := &lanTunnel{
		id:      id,
		ctx:     tunnelCtx,
		cancel:  cancel,
		session: session,
		ready:   make(chan struct{}, 1),
		changed: make(chan struct{}),
	}
	if err := session.reserveTunnel(tunnel); err != nil {
		cancel()
		return nil, err
	}

	dialCtx, dialCancel := context.WithTimeout(ctx, timeout)
	defer dialCancel()
	var dialer net.Dialer
	conn, err := dialer.DialContext(dialCtx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		session.removeTunnel(id, tunnel)
		cancel()
		return nil, err
	}
	if !tunnel.attach(conn) {
		_ = conn.Close()
		session.removeTunnel(id, tunnel)
		return nil, errors.New("tunnel closed before the connection opened")
	}
	go tunnel.closeWhenDone()
	go tunnel.writeLoop()
	go tunnel.readLoop()
	return map[string]any{
		"status":         "connected",
		"remote_address": conn.RemoteAddr().String(),
		"window":         lanTunnelWindow,
		"max_frame":      lanTunnelMaxFrame,
	}, nil
}

func (t *lanTunnel) attach(conn net.Conn) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return false
	}
	t.conn = conn
	return true
}

func (t *lanTunnel) closeWhenDone() {
	<-t.ctx.Done()
	t.finish("connector stopped the tunnel", true)
}

// finish closes the tunnel once. notify tells the server, unless the server
// closed it first.
func (t *lanTunnel) finish(reason string, notify bool) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	t.closed = true
	t.reason = reason
	conn := t.conn
	close(t.changed)
	t.mu.Unlock()

	t.cancel()
	if conn != nil {
		_ = conn.Close()
	}
	t.session.removeTunnel(t.id, t)
	if notify {
		ctx, cancel := context.WithTimeout(t.session.ownerCtx, scopeAbortNotifyTimeout)
		defer cancel()
		_ = t.session.sendCtx(ctx, message{
			ID:     t.id,
			Type:   "stream",
			Error:  reason,
			Stream: &streamData{Channel: lanTunnelChannel, EOF: true},
		})
	}
}

func (t *lanTunnel) readLoop() {
	buf := make([]byte, lanTunnelMaxFrame)
	for {
		room := t.waitWindow()
		if room <= 0 {
			return
		}
		n, err := t.conn.Read(buf[:min(room, len(buf))])
		if n > 0 {
			t.mu.Lock()
			t.sent += int64(n)
			t.mu.Unlock()
			sendErr := t.session.sendCtx(t.ctx, message{
				ID:   t.id,
				Type: "stream",
				Stream: &streamData{
					Channel: lanTunnelChannel,
					Data:    base64.StdEncoding.EncodeToString(buf[:n]),
				},
			})
			if sendErr != nil {
				t.finish("connector socket closed", false)
				return
			}
		}
		if err != nil {
			reason := ""
			if !errors.Is(err, net.ErrClosed) && !errors.Is(err, io.EOF) {
				reason = err.Error()
			}
			t.finish(reason, true)
			return
		}
	}
}

// waitWindow blocks while a full window is unacknowledged and returns how
// many bytes may be sent, or 0 once the tunnel closed. A sender never has
// more than one window unacknowledged.
func (t *lanTunnel) waitWindow() int {
	for {
		t.mu.Lock()
		if t.closed {
			t.mu.Unlock()
			return 0
		}
		if room := lanTunnelWindow - (t.sent - t.acked); room > 0 {
			t.mu.Unlock()
			return int(room)
		}
		changed := t.changed
		t.mu.Unlock()
		select {
		case <-changed:
		case <-t.ctx.Done():
			return 0
		}
	}
}

func (t *lanTunnel) writeLoop() {
	var written int64
	for {
		data, ok := t.next()
		if !ok {
			return
		}
		if _, err := t.conn.Write(data); err != nil {
			t.finish(err.Error(), true)
			return
		}
		written += int64(len(data))
		if err := t.session.sendCtx(t.ctx, message{
			ID:     t.id,
			Type:   "stream",
			Stream: &streamData{Channel: lanTunnelAckChannel, Seq: int(written)},
		}); err != nil {
			t.finish("connector socket closed", false)
			return
		}
	}
}

// next waits for the oldest queued server bytes.
func (t *lanTunnel) next() ([]byte, bool) {
	for {
		t.mu.Lock()
		if t.closed {
			t.mu.Unlock()
			return nil, false
		}
		if len(t.incoming) > 0 {
			data := t.incoming[0]
			t.incoming = t.incoming[1:]
			t.queued -= int64(len(data))
			t.mu.Unlock()
			return data, true
		}
		t.mu.Unlock()
		select {
		case <-t.ready:
		case <-t.ctx.Done():
			return nil, false
		}
	}
}

// receive handles one server frame without blocking the socket read loop.
func (t *lanTunnel) receive(msg message) {
	switch {
	case msg.Stream.Channel == lanTunnelAckChannel:
		t.mu.Lock()
		if int64(msg.Stream.Seq) > t.acked && int64(msg.Stream.Seq) <= t.sent {
			t.acked = int64(msg.Stream.Seq)
			if !t.closed {
				close(t.changed)
				t.changed = make(chan struct{})
			}
		}
		t.mu.Unlock()
	case msg.Stream.EOF || msg.Error != "":
		t.finish("", false)
	case msg.Stream.Data != "":
		data, err := base64.StdEncoding.DecodeString(msg.Stream.Data)
		if err != nil || len(data) > lanTunnelMaxFrame {
			go t.finish("invalid tunnel frame", true)
			return
		}
		t.mu.Lock()
		over := t.queued+int64(len(data)) > lanTunnelWindow
		if !over && !t.closed {
			t.queued += int64(len(data))
			t.incoming = append(t.incoming, data)
		}
		t.mu.Unlock()
		if over {
			go t.finish("tunnel window exceeded", true)
			return
		}
		select {
		case t.ready <- struct{}{}:
		default:
		}
	}
}

func (s *connectionSession) reserveTunnel(t *lanTunnel) error {
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()
	if s.tunnels == nil {
		s.tunnels = map[string]*lanTunnel{}
	}
	if _, exists := s.tunnels[t.id]; exists {
		return errors.New("tunnel already exists")
	}
	if len(s.tunnels) >= lanTunnelMaxOpen {
		return errors.New("tunnel capacity exhausted")
	}
	s.tunnels[t.id] = t
	return nil
}

func (s *connectionSession) removeTunnel(id string, t *lanTunnel) {
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()
	if s.tunnels[id] == t {
		delete(s.tunnels, id)
	}
}

// routeTunnelFrame delivers a tunnel frame in socket order. It reports
// whether the frame belonged to the tunnel protocol.
func (s *connectionSession) routeTunnelFrame(msg message) bool {
	if msg.Stream == nil || (msg.Stream.Channel != lanTunnelChannel && msg.Stream.Channel != lanTunnelAckChannel) {
		return false
	}
	s.pendingMu.Lock()
	t := s.tunnels[msg.ID]
	s.pendingMu.Unlock()
	if t != nil {
		t.receive(msg)
	}
	return true
}
