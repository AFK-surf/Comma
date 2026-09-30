// Package gateway dials Tailcat servers for Salix outbound SSH.
//
// One gateway process serves one Salix node. The node connects to the
// gateway's Unix socket once per SSH connection and sends one dial request.
// The gateway answers with one reply frame and then copies raw bytes between
// the socket and a TCP connection to the Tailcat server's port.
//
// Each connection gets its own tailcat.Client with a new ephemeral node key.
// Nothing is pooled or stored: the Agents of one Group run on many nodes at
// once, and two peers that present the same node key to one server would
// replace each other there.
package gateway

import (
	"context"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// MaxFrame bounds one request or reply frame.
const MaxFrame = 16 << 10

const (
	defaultDialTime = 20 * time.Second
	requestTime     = 5 * time.Second
	// drainTime bounds the wait for the last FIN and ACK before a client's
	// network stack closes.
	drainTime = 5 * time.Second
)

// Config configures a Gateway.
type Config struct {
	// Token authenticates dial requests. It is required.
	Token string
	// DERPMapURL is the trusted DERP map. Relays come only from this map,
	// never from the address. Empty means tailcat.DefaultDERPMapURL.
	DERPMapURL string
	// Logf receives tailcat's debug logs. Nil discards them.
	Logf logger.Logf
}

// Request is the dial request frame.
type Request struct {
	Token string `json:"token"`
	// Address is a tailcat address or a DNS name with a "tailcat=" TXT record.
	Address   string `json:"address"`
	Port      int    `json:"port"`
	TimeoutMS int    `json:"timeout_ms"`
}

// Reply is the dial reply frame.
type Reply struct {
	OK            bool   `json:"ok"`
	ServerNodeKey string `json:"server_node_key,omitempty"`
	Code          string `json:"code,omitempty"`
	Message       string `json:"message,omitempty"`
}

// Error is a dial failure with a stable code for the Agent.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func fail(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// Gateway serves dial requests, one tailcat client per connection.
type Gateway struct {
	cfg Config

	mu      sync.Mutex
	clients map[*tailcat.Client]struct{}
}

// New returns a Gateway. It does no network access.
func New(cfg Config) (*Gateway, error) {
	if cfg.Token == "" {
		return nil, errors.New("gateway: token required")
	}
	if cfg.DERPMapURL == "" {
		cfg.DERPMapURL = tailcat.DefaultDERPMapURL
	}
	if cfg.Logf == nil {
		cfg.Logf = logger.Discard
	}
	return &Gateway{cfg: cfg, clients: map[*tailcat.Client]struct{}{}}, nil
}

// Serve accepts connections until ln closes.
func (g *Gateway) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go g.handle(c)
	}
}

// Close closes every client, which ends their connections.
func (g *Gateway) Close() {
	g.mu.Lock()
	defer g.mu.Unlock()
	for c := range g.clients {
		c.Close()
		delete(g.clients, c)
	}
}

// Conns reports open connections (dialing or connected).
func (g *Gateway) Conns() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.clients)
}

func (g *Gateway) handle(local net.Conn) {
	defer local.Close()
	local.SetDeadline(time.Now().Add(requestTime))
	var req Request
	if err := ReadFrame(local, &req); err != nil {
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Token), []byte(g.cfg.Token)) != 1 {
		WriteFrame(local, Reply{Code: "tailcat_unavailable", Message: "The gateway refused the request."})
		return
	}
	local.SetDeadline(time.Time{})

	client, remote, server, err := g.dial(req)
	if err != nil {
		var e *Error
		if !errors.As(err, &e) {
			e = fail("tailcat_unavailable", "%v", err)
		}
		WriteFrame(local, Reply{Code: e.Code, Message: e.Message})
		return
	}
	defer g.release(client)
	defer remote.Close()

	if WriteFrame(local, Reply{OK: true, ServerNodeKey: server.String()}) != nil {
		return
	}
	splice(local, remote)
}

func (g *Gateway) dial(req Request) (*tailcat.Client, net.Conn, key.NodePublic, error) {
	var zero key.NodePublic
	if req.Port < 1 || req.Port > 65535 {
		return nil, nil, zero, fail("tailcat_invalid_address", "port %d is out of range", req.Port)
	}
	timeout := time.Duration(req.TimeoutMS) * time.Millisecond
	if timeout <= 0 || timeout > time.Minute {
		timeout = defaultDialTime
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	addr, server, err := Resolve(ctx, req.Address, g.cfg.DERPMapURL)
	if err != nil {
		return nil, nil, zero, err
	}
	client := g.acquire(addr)
	// Ping first, so an unanswered announcement and a refused port get
	// different codes.
	if _, err := client.Ping(ctx); err != nil {
		g.release(client)
		return nil, nil, zero, fail("tailcat_unreachable",
			"The Tailcat server did not answer. It is offline, or it admits only listed client keys (--allow). Each connection uses a new ephemeral key, so such a server cannot admit it.")
	}
	conn, err := client.DialTCPPort(ctx, uint16(req.Port))
	if err != nil {
		g.release(client)
		return nil, nil, zero, fail("tailcat_connect_failed",
			"The Tailcat server answered, but port %d refused or did not accept the connection.", req.Port)
	}
	return client, conn, server, nil
}

// acquire creates the client for one connection. There is no node-wide
// limit: each Agent session already holds at most a few SSH connections.
func (g *Gateway) acquire(addr tailcat.Addr) *tailcat.Client {
	g.mu.Lock()
	defer g.mu.Unlock()
	c := &tailcat.Client{
		Server:     addr,
		Key:        key.NewNode(), // ephemeral: never stored, never reused
		Logf:       g.cfg.Logf,
		DERPMapURL: g.cfg.DERPMapURL,
	}
	g.clients[c] = struct{}{}
	return c
}

// release closes a client after its connection ends. It first waits, for a
// bounded time, until the last segments are sent, so the server sees the
// close instead of a silent peer.
func (g *Gateway) release(c *tailcat.Client) {
	ctx, cancel := context.WithTimeout(context.Background(), drainTime)
	c.DrainTCP(ctx)
	cancel()
	c.Close()
	g.mu.Lock()
	delete(g.clients, c)
	g.mu.Unlock()
}

func splice(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	// SSH ends when either side ends; close both.
	<-done
	a.Close()
	b.Close()
	<-done
}

// ReadFrame reads one length-prefixed JSON frame.
func ReadFrame(r io.Reader, v any) error {
	var n uint32
	if err := binary.Read(r, binary.BigEndian, &n); err != nil {
		return err
	}
	if n == 0 || n > MaxFrame {
		return fmt.Errorf("frame of %d bytes", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	return json.Unmarshal(buf, v)
}

// WriteFrame writes one length-prefixed JSON frame.
func WriteFrame(w io.Writer, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(body) > MaxFrame {
		return fmt.Errorf("frame of %d bytes", len(body))
	}
	buf := binary.BigEndian.AppendUint32(make([]byte, 0, 4+len(body)), uint32(len(body)))
	_, err = w.Write(append(buf, body...))
	return err
}
