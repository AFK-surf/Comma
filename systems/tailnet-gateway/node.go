package gateway

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

// refreshEvery re-reads the node status, so key expiry and tailnet renames
// reach the owner without a notification.
const refreshEvery = 30 * time.Second

// node is one Group's tsnet node.
type node struct {
	g            *Gateway
	groupID      string
	epoch        int64
	acceptRoutes bool
	ctx          context.Context
	cancel       context.CancelFunc
	// startCtx ends when close begins, so a start in progress gives up
	// while ctx still serves the logout's state write.
	startCtx    context.Context
	cancelStart context.CancelFunc

	closeOnce sync.Once
	closed    chan struct{}
	// tried closes when the start attempt ends, run or not, so a logout
	// waits for a start still queued for a slot.
	tried chan struct{}
	// life serializes start and close, so a node closed while it starts
	// never leaves a running tsnet server behind.
	life sync.Mutex

	mu      sync.Mutex
	srv     *tsnet.Server
	lc      *local.Client
	dir     string
	status  Status
	changed chan struct{} // closed and replaced on every status change
	conns   int           // open connections, reported as activity
	pending int           // requests in progress; with conns at most maxRequests
	login   bool          // a login link was requested (by tsnet or refresh) in this NeedsLogin episode
}

func newNode(g *Gateway, m PortMessage) *node {
	ctx, cancel := context.WithCancel(context.Background())
	startCtx, cancelStart := context.WithCancel(ctx)
	n := &node{
		g:            g,
		groupID:      m.GroupID,
		epoch:        m.Epoch,
		acceptRoutes: m.AcceptRoutes,
		ctx:          ctx,
		cancel:       cancel,
		startCtx:     startCtx,
		cancelStart:  cancelStart,
		closed:       make(chan struct{}),
		tried:        make(chan struct{}),
		changed:      make(chan struct{}),
	}
	n.status = n.frame("starting")
	return n
}

func (n *node) frame(status string) Status {
	return Status{Type: "status", GroupID: n.groupID, Epoch: n.epoch, Status: status}
}

func (n *node) run(m PortMessage) {
	select {
	case n.g.slots <- struct{}{}:
	case <-n.startCtx.Done():
		close(n.tried)
		return
	}
	err := n.start(m)
	<-n.g.slots
	close(n.tried)
	if n.startCtx.Err() != nil {
		return
	}
	if err != nil {
		st := n.frame("error")
		st.Code, st.Message = "tailnet_unavailable", "The tailnet node did not start: "+err.Error()
		n.setStatus(st)
		n.close(false)
		return
	}
	n.watch()
}

func (n *node) start(m PortMessage) error {
	n.life.Lock()
	defer n.life.Unlock()
	if err := n.startCtx.Err(); err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(n.groupID))
	dir := filepath.Join(n.g.cfg.Dir, hex.EncodeToString(sum[:8]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	store := newStateStore(m.State, func(state map[string][]byte) error {
		err := n.g.persist(n.ctx, n.groupID, n.epoch, state)
		if err != nil {
			// The owner lost its lease or cannot save. Stop instead of running
			// with keys nobody recorded. Not inline: this runs inside tsnet.
			st := n.frame("error")
			st.Code, st.Message = "tailnet_state_not_saved", "The tailnet node state could not be saved: "+err.Error()
			n.setStatus(st)
			go n.close(false)
		}
		return err
	})
	srv := &tsnet.Server{
		Dir:           dir,
		Store:         store,
		Hostname:      m.Hostname,
		Ephemeral:     false,
		AdvertiseTags: m.Tags,
		ControlURL:    n.g.cfg.ControlURL,
		Logf:          n.g.cfg.Logf,
		UserLogf:      logger.Discard,
	}
	n.mu.Lock()
	n.srv, n.dir = srv, dir
	n.mu.Unlock()
	if err := srv.Start(); err != nil {
		return err
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return err
	}
	// tsnet asks for a login link itself when the node needs a login at
	// start. Another interactive login before the link arrives would
	// register a second node key, so refresh must not add one.
	ctx, cancel := context.WithTimeout(n.startCtx, 10*time.Second)
	defer cancel()
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return err
	}
	n.mu.Lock()
	n.lc = lc
	n.login = st.BackendState == ipn.NeedsLogin.String()
	n.mu.Unlock()
	// A restored node keeps its stored prefs, so apply the owner's settings
	// every time. Shields up: Agents are clients only.
	prefs := &ipn.MaskedPrefs{
		Prefs: ipn.Prefs{
			RouteAll:      m.AcceptRoutes,
			ShieldsUp:     true,
			AdvertiseTags: m.Tags,
			Hostname:      m.Hostname,
		},
		RouteAllSet:      true,
		ShieldsUpSet:     true,
		AdvertiseTagsSet: true,
		HostnameSet:      m.Hostname != "",
	}
	_, err = lc.EditPrefs(ctx, prefs)
	return err
}

func (n *node) watch() {
	n.refresh()
	go func() {
		ticker := time.NewTicker(refreshEvery)
		defer ticker.Stop()
		for {
			select {
			case <-n.ctx.Done():
				return
			case <-ticker.C:
				n.refresh()
			}
		}
	}()
	w, err := n.lc.WatchIPNBus(n.ctx, ipn.NotifyInitialState)
	if err != nil {
		return
	}
	defer w.Close()
	for {
		msg, err := w.Next()
		if err != nil {
			return
		}
		if msg.State != nil || msg.BrowseToURL != nil || msg.LoginFinished != nil || msg.ErrMessage != nil {
			n.refresh()
		}
	}
}

// refresh maps the backend state to the owner's status and emits it when it
// changed.
func (n *node) refresh() {
	ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
	defer cancel()
	st, err := n.lc.StatusWithoutPeers(ctx)
	if err != nil {
		return
	}
	out := n.frame("starting")
	switch st.BackendState {
	case ipn.Running.String():
		out.Status = "running"
		n.mu.Lock()
		n.login = false
		n.mu.Unlock()
		if st.CurrentTailnet != nil {
			out.Tailnet = st.CurrentTailnet.Name
			out.MagicDNSSuffix = st.CurrentTailnet.MagicDNSSuffix
		}
		if self := st.Self; self != nil {
			out.NodeName = strings.TrimSuffix(self.DNSName, ".")
			for _, ip := range self.TailscaleIPs {
				out.SelfIPs = append(out.SelfIPs, ip.String())
			}
			if self.Tags != nil {
				out.Tags = self.Tags.AsSlice()
			}
			if len(out.Tags) == 0 {
				if user, ok := st.User[self.UserID]; ok {
					out.LoginName = user.LoginName
				}
			}
			out.KeyExpiry = self.KeyExpiry
		}
	case ipn.NeedsLogin.String():
		out.Status = "needs_login"
		out.AuthURL = st.AuthURL
		n.mu.Lock()
		start := st.AuthURL == "" && !n.login
		n.login = n.login || start
		n.mu.Unlock()
		if start {
			// tsnet asks for a login link only at start. A key that expires
			// later needs a new one.
			go n.lc.StartLoginInteractive(n.ctx)
		}
	case ipn.NeedsMachineAuth.String():
		out.Status = "needs_approval"
	}
	n.setStatus(out)
}

func (n *node) setStatus(st Status) {
	n.mu.Lock()
	same := statusEqual(n.status, st)
	if !same {
		n.status = st
		close(n.changed)
		n.changed = make(chan struct{})
	}
	n.mu.Unlock()
	if !same {
		n.g.cfg.Emit(st)
	}
}

func statusEqual(a, b Status) bool {
	ae, be := a.KeyExpiry, b.KeyExpiry
	a.KeyExpiry, b.KeyExpiry = nil, nil
	return a.Status == b.Status && a.AuthURL == b.AuthURL && a.Tailnet == b.Tailnet &&
		a.MagicDNSSuffix == b.MagicDNSSuffix && a.NodeName == b.NodeName &&
		a.LoginName == b.LoginName && slices.Equal(a.Tags, b.Tags) &&
		slices.Equal(a.SelfIPs, b.SelfIPs) && a.Code == b.Code && a.Message == b.Message &&
		((ae == nil && be == nil) || (ae != nil && be != nil && ae.Equal(*be)))
}

func (n *node) emitStatus() {
	n.mu.Lock()
	st := n.status
	n.mu.Unlock()
	n.g.cfg.Emit(st)
}

// awaitRunning waits until the node runs, or fails with the reason it cannot
// serve a dial.
func (n *node) awaitRunning(ctx context.Context) (*tsnet.Server, *local.Client, error) {
	for {
		n.mu.Lock()
		st, changed, srv, lc := n.status, n.changed, n.srv, n.lc
		n.mu.Unlock()
		switch st.Status {
		case "running":
			return srv, lc, nil
		case "needs_login":
			return nil, nil, fail("tailnet_needs_login",
				"The Group's tailnet node is waiting for a tailnet admin to approve its login link. Call tailnet.status.")
		case "needs_approval":
			return nil, nil, fail("tailnet_needs_login",
				"The tailnet admin must approve the Group's node in the Tailscale admin console.")
		case "error", "stopped":
			return nil, nil, fail(orDefault(st.Code, "tailnet_unavailable"), "%s", orDefault(st.Message, "The tailnet node stopped."))
		}
		select {
		case <-changed:
		case <-n.closed:
			return nil, nil, fail("tailnet_not_running", "The tailnet node stopped.")
		case <-ctx.Done():
			return nil, nil, fail("tailnet_starting", "The tailnet node is still starting. Retry shortly.")
		}
	}
}

func (n *node) dial(ctx context.Context, host string, port int) (net.Conn, Target, string, error) {
	if port < 1 || port > 65535 {
		return nil, Target{}, "", fail("tailnet_destination_not_allowed", "Port %d is out of range.", port)
	}
	srv, lc, err := n.awaitRunning(ctx)
	if err != nil {
		return nil, Target{}, "", err
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return nil, Target{}, "", fail("tailnet_unavailable", "The tailnet node status is unavailable.")
	}
	target, err := Resolve(st, host, n.acceptRoutes)
	if err != nil {
		return nil, Target{}, "", err
	}
	// Netstack only: tsnet's Dial falls back to the host network for an
	// address without a tailnet route, and a route can vanish between the
	// check and the dial.
	conn, err := srv.Sys().Dialer.Get().NetstackDialTCP(ctx, netip.AddrPortFrom(target.Addr, uint16(port)))
	if err != nil {
		return nil, Target{}, "", fail("tailnet_connect_failed",
			"%s (%s) did not accept a connection on port %d. The device is offline, the tailnet policy denies this port, or nothing listens on it.",
			target.Peer, target.Addr, port)
	}
	return conn, target, tailnetName(st), nil
}

func (n *node) peers(ctx context.Context, cursor int) ([]Peer, int, string, error) {
	_, lc, err := n.awaitRunning(ctx)
	if err != nil {
		return nil, 0, "", err
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return nil, 0, "", fail("tailnet_unavailable", "The tailnet node status is unavailable.")
	}
	peers, next := Peers(st, cursor)
	return peers, next, tailnetName(st), nil
}

func tailnetName(st *ipnstate.Status) string {
	if st.CurrentTailnet != nil {
		return st.CurrentTailnet.Name
	}
	return ""
}

// acquire takes a slot for a request.
func (n *node) acquire() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.pending+n.conns >= maxRequests {
		return false
	}
	n.pending++
	return true
}

// release frees the slot of a request that opened no connection.
func (n *node) release() {
	n.mu.Lock()
	n.pending--
	n.mu.Unlock()
}

// track moves a request's slot to its new connection (1) or frees the
// slot of a closed connection (-1), then reports the open connections.
func (n *node) track(delta int) {
	n.mu.Lock()
	if delta > 0 {
		n.pending--
	}
	n.conns += delta
	conns := n.conns
	n.mu.Unlock()
	n.g.cfg.Emit(Activity{Type: "activity", GroupID: n.groupID, Epoch: n.epoch, Conns: conns})
}

// close stops the node once. With logout it first deregisters the node key,
// so the tailnet admin sees the Group leave, and reports whether it did.
func (n *node) close(logout bool) {
	n.closeOnce.Do(func() {
		if logout {
			// A logout needs the node started, also when its start still
			// waits for a slot.
			<-n.tried
		} else {
			n.cancelStart()
		}
		n.life.Lock()
		defer n.life.Unlock()
		n.mu.Lock()
		srv, lc, dir := n.srv, n.lc, n.dir
		n.mu.Unlock()
		loggedOut := false
		if logout && lc != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			loggedOut = lc.Logout(ctx) == nil
			cancel()
		}
		n.cancel()
		if srv != nil {
			srv.Close()
		}
		if dir != "" {
			os.RemoveAll(dir)
		}
		close(n.closed)
		n.g.remove(n)
		n.g.cfg.Emit(Stopped{Type: "stopped", GroupID: n.groupID, Epoch: n.epoch, LoggedOut: loggedOut})
	})
}

func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}
