// Package gateway connects Salix Agent Groups to their tailnets.
//
// One gateway process serves one Salix node. It runs one tsnet node for each
// Group whose tailnet lease that Salix node holds. The node identity (machine
// and node keys) lives in the state the owner gives at start; every change to
// it goes back to the owner before it takes effect, so it stays durable under
// the owner's lease.
//
// Agents reach the tailnet through the Unix socket: one dial request per
// connection, one reply frame, then raw bytes. Dials go only through the
// node's netstack, never through the Pod network, and only to peers or
// approved subnet routes.
package gateway

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/types/logger"
)

const (
	requestTime        = 5 * time.Second
	defaultDialTime    = 20 * time.Second
	defaultPersistTime = 10 * time.Second
	// startSlots bounds concurrent node starts on one Salix node.
	startSlots = 4
	// maxRequests bounds one node's requests in progress and open
	// connections. Each connection holds netstack buffers.
	maxRequests = 64
	// forgetAfter keeps a stopped run's epoch, so a request for it that was
	// already on its way fails at once. It exceeds the longest request wait.
	forgetAfter = 2 * time.Minute
)

// Config configures a Gateway.
type Config struct {
	// Token authenticates socket requests. It is required.
	Token string
	// Dir is the parent of the nodes' scratch directories. It is required.
	Dir string
	// ControlURL is the coordination server. Empty means Tailscale's.
	// Only tests set it.
	ControlURL string
	// Emit sends one frame to the owner. It is required and must be safe
	// for concurrent use.
	Emit func(v any) error
	// PersistTimeout bounds the wait for the owner to save a state change.
	PersistTimeout time.Duration
	// Logf receives tsnet's debug logs. Nil discards them.
	Logf logger.Logf
}

// PortMessage is a frame from the owner.
type PortMessage struct {
	Type string `json:"type"`

	// start and stop
	GroupID      string            `json:"group_id"`
	Epoch        int64             `json:"epoch"`
	Hostname     string            `json:"hostname"`
	Tags         []string          `json:"tags"`
	AcceptRoutes bool              `json:"accept_routes"`
	State        map[string][]byte `json:"state"`
	Logout       bool              `json:"logout"`

	// persisted
	Seq uint64 `json:"seq"`
	OK  bool   `json:"ok"`
}

// Status is the node state frame.
type Status struct {
	Type           string     `json:"type"`
	GroupID        string     `json:"group_id"`
	Epoch          int64      `json:"epoch"`
	Status         string     `json:"status"`
	AuthURL        string     `json:"auth_url,omitempty"`
	Tailnet        string     `json:"tailnet,omitempty"`
	MagicDNSSuffix string     `json:"magic_dns_suffix,omitempty"`
	NodeName       string     `json:"node_name,omitempty"`
	LoginName      string     `json:"login_name,omitempty"`
	Tags           []string   `json:"tags,omitempty"`
	SelfIPs        []string   `json:"self_ips,omitempty"`
	KeyExpiry      *time.Time `json:"key_expiry,omitempty"`
	Code           string     `json:"code,omitempty"`
	Message        string     `json:"message,omitempty"`
}

// Persist asks the owner to save a state snapshot and answer with persisted.
type Persist struct {
	Type    string            `json:"type"`
	GroupID string            `json:"group_id"`
	Epoch   int64             `json:"epoch"`
	Seq     uint64            `json:"seq"`
	State   map[string][]byte `json:"state"`
}

// Activity reports open connections, so the owner can stop an idle node.
type Activity struct {
	Type    string `json:"type"`
	GroupID string `json:"group_id"`
	Epoch   int64  `json:"epoch"`
	Conns   int    `json:"conns"`
}

// Stopped reports that a node closed.
type Stopped struct {
	Type    string `json:"type"`
	GroupID string `json:"group_id"`
	Epoch   int64  `json:"epoch"`
	// LoggedOut reports that the stop's logout left the tailnet.
	LoggedOut bool `json:"logged_out,omitempty"`
}

// Request is a socket request frame.
type Request struct {
	Token     string `json:"token"`
	Op        string `json:"op"` // "dial" or "peers"
	GroupID   string `json:"group_id"`
	Epoch     int64  `json:"epoch"`
	Host      string `json:"host,omitempty"`
	Port      int    `json:"port,omitempty"`
	TimeoutMS int    `json:"timeout_ms,omitempty"`
	Cursor    int    `json:"cursor,omitempty"`
}

// Reply is a socket reply frame.
type Reply struct {
	OK      bool   `json:"ok"`
	Addr    string `json:"addr,omitempty"`
	Peer    string `json:"peer,omitempty"`
	Tailnet string `json:"tailnet,omitempty"`
	Peers   []Peer `json:"peers,omitempty"`
	Next    int    `json:"next,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// Error is a failure with a stable code for the Agent.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func fail(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// Gateway runs the nodes of the Groups this Salix node owns.
type Gateway struct {
	cfg   Config
	slots chan struct{}
	seq   atomic.Uint64

	mu      sync.Mutex
	nodes   map[string]*node
	latest  map[string]int64 // the last epoch started for each Group, kept forgetAfter past its stop
	started chan struct{}    // closed and replaced on every start

	pmu     sync.Mutex
	pending map[uint64]chan bool
}

// New returns a Gateway. It does no network access.
func New(cfg Config) (*Gateway, error) {
	if cfg.Token == "" || cfg.Dir == "" || cfg.Emit == nil {
		return nil, errors.New("gateway: token, dir and emit are required")
	}
	if cfg.PersistTimeout <= 0 {
		cfg.PersistTimeout = defaultPersistTime
	}
	if cfg.Logf == nil {
		cfg.Logf = logger.Discard
	}
	return &Gateway{
		cfg:     cfg,
		slots:   make(chan struct{}, startSlots),
		nodes:   map[string]*node{},
		latest:  map[string]int64{},
		started: make(chan struct{}),
		pending: map[uint64]chan bool{},
	}, nil
}

// HandlePort applies one frame from the owner. It never blocks on the
// network: starts and stops run in their own goroutines.
func (g *Gateway) HandlePort(m PortMessage) {
	switch m.Type {
	case "start":
		g.start(m)
	case "stop":
		go g.stop(m.GroupID, m.Epoch, m.Logout)
	case "persisted":
		g.pmu.Lock()
		ch := g.pending[m.Seq]
		delete(g.pending, m.Seq)
		g.pmu.Unlock()
		if ch != nil {
			ch <- m.OK
		}
	}
}

func (g *Gateway) start(m PortMessage) {
	g.mu.Lock()
	old := g.nodes[m.GroupID]
	if old != nil && old.epoch == m.Epoch {
		g.mu.Unlock()
		old.emitStatus()
		return
	}
	n := newNode(g, m)
	g.nodes[m.GroupID] = n
	g.latest[m.GroupID] = max(g.latest[m.GroupID], m.Epoch)
	close(g.started)
	g.started = make(chan struct{})
	g.mu.Unlock()
	go func() {
		if old != nil {
			old.close(false)
		}
		n.run(m)
	}()
}

func (g *Gateway) stop(groupID string, epoch int64, logout bool) {
	g.mu.Lock()
	n := g.nodes[groupID]
	g.mu.Unlock()
	if n == nil || n.epoch != epoch {
		g.cfg.Emit(Stopped{Type: "stopped", GroupID: groupID, Epoch: epoch})
		return
	}
	n.close(logout)
}

func (g *Gateway) remove(n *node) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.nodes[n.groupID] != n {
		return
	}
	delete(g.nodes, n.groupID)
	time.AfterFunc(forgetAfter, func() {
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.nodes[n.groupID] == nil && g.latest[n.groupID] == n.epoch {
			delete(g.latest, n.groupID)
		}
	})
}

// node returns the Group's node of run epoch. The owner sends the start on
// the port and a request on the socket, so a request can arrive before its
// start: it waits for that start until ctx ends. An older run, or a run
// stopped less than forgetAfter ago, returns nil at once.
func (g *Gateway) node(ctx context.Context, groupID string, epoch int64) *node {
	for {
		g.mu.Lock()
		n, latest, started := g.nodes[groupID], g.latest[groupID], g.started
		g.mu.Unlock()
		switch {
		case n != nil && n.epoch == epoch:
			return n
		case latest >= epoch:
			return nil
		}
		select {
		case <-started:
		case <-ctx.Done():
			return nil
		}
	}
}

// persist sends a snapshot to the owner and waits for its answer.
func (g *Gateway) persist(ctx context.Context, groupID string, epoch int64, state map[string][]byte) error {
	seq := g.seq.Add(1)
	ch := make(chan bool, 1)
	g.pmu.Lock()
	g.pending[seq] = ch
	g.pmu.Unlock()
	defer func() {
		g.pmu.Lock()
		delete(g.pending, seq)
		g.pmu.Unlock()
	}()
	if err := g.cfg.Emit(Persist{Type: "persist", GroupID: groupID, Epoch: epoch, Seq: seq, State: state}); err != nil {
		return err
	}
	timer := time.NewTimer(g.cfg.PersistTimeout)
	defer timer.Stop()
	select {
	case ok := <-ch:
		if !ok {
			return errors.New("the owner refused the state")
		}
		return nil
	case <-timer.C:
		return errors.New("the owner did not save the state in time")
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Close stops every node without logging out. The nodes stay registered in
// their tailnets, so the next owner restores them from the saved state.
func (g *Gateway) Close() {
	g.mu.Lock()
	nodes := make([]*node, 0, len(g.nodes))
	for _, n := range g.nodes {
		nodes = append(nodes, n)
	}
	g.mu.Unlock()
	var wg sync.WaitGroup
	for _, n := range nodes {
		wg.Go(func() { n.close(false) })
	}
	wg.Wait()
}

// Serve accepts socket connections until ln closes.
func (g *Gateway) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go g.handle(c)
	}
}

func (g *Gateway) handle(local net.Conn) {
	defer local.Close()
	local.SetDeadline(time.Now().Add(requestTime))
	var req Request
	if err := ReadFrame(local, MaxSocketFrame, &req); err != nil {
		return
	}
	reply := func(r Reply) error { return WriteFrame(local, MaxSocketFrame, r) }
	failed := func(err error) {
		var e *Error
		if !errors.As(err, &e) {
			e = fail("tailnet_unavailable", "%v", err)
		}
		reply(Reply{Code: e.Code, Message: e.Message})
	}
	if subtle.ConstantTimeCompare([]byte(req.Token), []byte(g.cfg.Token)) != 1 {
		reply(Reply{Code: "tailnet_unavailable", Message: "The gateway refused the request."})
		return
	}
	timeout := time.Duration(req.TimeoutMS) * time.Millisecond
	if timeout <= 0 || timeout > time.Minute {
		timeout = defaultDialTime
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	local.SetDeadline(time.Now().Add(timeout + requestTime))
	n := g.node(ctx, req.GroupID, req.Epoch)
	if n == nil {
		reply(Reply{Code: "tailnet_not_running", Message: "The Group's tailnet node is not running on this Salix node."})
		return
	}
	if !n.acquire() {
		reply(Reply{Code: "tailnet_busy", Message: fmt.Sprintf(
			"The Group already has %d tailnet connections and requests open. Close an SSH session or retry after other requests finish.", maxRequests)})
		return
	}

	switch req.Op {
	case "peers":
		defer n.release()
		peers, next, tailnet, err := n.peers(ctx, req.Cursor)
		if err != nil {
			failed(err)
			return
		}
		reply(Reply{OK: true, Peers: peers, Next: next, Tailnet: tailnet})
	case "dial":
		remote, target, tailnet, err := n.dial(ctx, req.Host, req.Port)
		if err != nil {
			n.release()
			failed(err)
			return
		}
		defer remote.Close()
		local.SetDeadline(time.Time{})
		// The request's slot becomes the connection's.
		n.track(1)
		defer n.track(-1)
		if reply(Reply{OK: true, Addr: target.Addr.String(), Peer: target.Peer, Tailnet: tailnet}) != nil {
			return
		}
		splice(local, remote)
	default:
		n.release()
		reply(Reply{Code: "tailnet_unavailable", Message: "Unknown request."})
	}
}

func splice(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	a.Close()
	b.Close()
	<-done
}
