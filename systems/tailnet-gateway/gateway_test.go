package gateway

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/views"
)

const token = "test-token"

func status(peers ...*ipnstate.PeerStatus) *ipnstate.Status {
	st := &ipnstate.Status{Peer: map[key.NodePublic]*ipnstate.PeerStatus{}}
	for _, p := range peers {
		st.Peer[key.NewNode().Public()] = p
	}
	return st
}

func routes(prefixes ...string) *views.Slice[netip.Prefix] {
	var out []netip.Prefix
	for _, p := range prefixes {
		out = append(out, netip.MustParsePrefix(p))
	}
	v := views.SliceOf(out)
	return &v
}

func code(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

func TestResolveAllowsOnlyPeersAndApprovedRoutes(t *testing.T) {
	st := status(
		&ipnstate.PeerStatus{
			DNSName:      "nas.example.ts.net.",
			HostName:     "nas",
			TailscaleIPs: []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::5"), netip.MustParseAddr("100.64.0.5")},
		},
		&ipnstate.PeerStatus{
			DNSName:       "router.example.ts.net.",
			TailscaleIPs:  []netip.Addr{netip.MustParseAddr("100.64.0.6")},
			PrimaryRoutes: routes("192.168.1.0/24", "0.0.0.0/0", "::/0"),
		},
	)

	for _, tc := range []struct {
		host, addr, code string
		acceptRoutes     bool
	}{
		{host: "nas", addr: "100.64.0.5"},
		{host: "NAS.example.ts.net.", addr: "100.64.0.5"},
		{host: "[fd7a:115c:a1e0::5]", addr: "fd7a:115c:a1e0::5"},
		{host: "100.64.0.6", addr: "100.64.0.6"},
		{host: "192.168.1.20", code: "tailnet_destination_not_allowed"},
		{host: "192.168.1.20", acceptRoutes: true, addr: "192.168.1.20"},
		// Exit-node routes never make the internet or the Pod network reachable.
		{host: "8.8.8.8", acceptRoutes: true, code: "tailnet_destination_not_allowed"},
		{host: "10.0.0.1", acceptRoutes: true, code: "tailnet_destination_not_allowed"},
		{host: "127.0.0.1", acceptRoutes: true, code: "tailnet_destination_not_allowed"},
		{host: "example.com", code: "tailnet_host_unknown"},
	} {
		got, err := Resolve(st, tc.host, tc.acceptRoutes)
		if tc.code != "" {
			if code(err) != tc.code {
				t.Errorf("Resolve(%q, %v) = %v, %v; want %s", tc.host, tc.acceptRoutes, got, err, tc.code)
			}
			continue
		}
		if err != nil || got.Addr.String() != tc.addr {
			t.Errorf("Resolve(%q, %v) = %v, %v; want %s", tc.host, tc.acceptRoutes, got, err, tc.addr)
		}
	}
}

func TestResolveRefusesAmbiguousShortNames(t *testing.T) {
	st := status(
		&ipnstate.PeerStatus{DNSName: "pi.a.ts.net.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.1")}},
		&ipnstate.PeerStatus{DNSName: "pi.b.ts.net.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.2")}},
	)
	if _, err := Resolve(st, "pi", false); code(err) != "tailnet_host_unknown" {
		t.Fatalf("ambiguous short name: %v", err)
	}
	if got, err := Resolve(st, "pi.b.ts.net", false); err != nil || got.Addr.String() != "100.64.0.2" {
		t.Fatalf("full name: %v %v", got, err)
	}
}

func TestStateStoreKeepsOldStateWhenPersistFails(t *testing.T) {
	refuse := false
	var saved map[string][]byte
	s := newStateStore(map[string][]byte{"a": []byte("1")}, func(m map[string][]byte) error {
		if refuse {
			return errors.New("lease lost")
		}
		saved = m
		return nil
	})
	if err := s.WriteState("b", []byte("2")); err != nil || string(saved["b"]) != "2" || string(saved["a"]) != "1" {
		t.Fatalf("write: %v %v", err, saved)
	}
	refuse = true
	if err := s.WriteState("a", []byte("3")); err == nil {
		t.Fatal("a refused write succeeded")
	}
	if v, _ := s.ReadState("a"); string(v) != "1" {
		t.Fatalf("refused write changed the state: %q", v)
	}
}

// owner records the gateway's frames and answers persist frames like the
// Salix owner does.
type owner struct {
	t      *testing.T
	g      *Gateway
	refuse bool

	mu     sync.Mutex
	frames []any
	state  map[int64]map[string][]byte
	notify chan struct{}
}

func newOwner(t *testing.T, controlURL string) *owner {
	o := &owner{t: t, state: map[int64]map[string][]byte{}, notify: make(chan struct{}, 1)}
	g, err := New(Config{
		Token:          token,
		Dir:            t.TempDir(),
		ControlURL:     controlURL,
		PersistTimeout: 5 * time.Second,
		Emit:           o.emit,
	})
	if err != nil {
		t.Fatal(err)
	}
	o.g = g
	t.Cleanup(g.Close)
	return o
}

func (o *owner) emit(v any) error {
	o.mu.Lock()
	o.frames = append(o.frames, v)
	refuse := o.refuse
	if p, ok := v.(Persist); ok && !refuse {
		o.state[p.Epoch] = p.State
	}
	o.mu.Unlock()
	if p, ok := v.(Persist); ok {
		go o.g.HandlePort(PortMessage{Type: "persisted", Seq: p.Seq, OK: !refuse})
	}
	select {
	case o.notify <- struct{}{}:
	default:
	}
	return nil
}

// await returns the first frame that matches.
func (o *owner) await(ctx context.Context, match func(any) bool) any {
	o.t.Helper()
	return o.awaitSince(ctx, 0, match)
}

// mark returns the number of frames so far, for awaitSince.
func (o *owner) mark() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.frames)
}

// awaitSince returns the first matching frame after the first from frames.
func (o *owner) awaitSince(ctx context.Context, from int, match func(any) bool) any {
	o.t.Helper()
	for {
		o.mu.Lock()
		for _, f := range o.frames[from:] {
			if match(f) {
				o.mu.Unlock()
				return f
			}
		}
		o.mu.Unlock()
		select {
		case <-o.notify:
		case <-ctx.Done():
			o.t.Fatalf("no matching frame; got %+v", o.frames)
		}
	}
}

func (o *owner) statusFor(ctx context.Context, epoch int64, want string) Status {
	return o.await(ctx, func(f any) bool {
		s, ok := f.(Status)
		return ok && s.Epoch == epoch && s.Status == want && (want != "needs_login" || s.AuthURL != "")
	}).(Status)
}

func startControl(t *testing.T) (*testcontrol.Server, string) {
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	control := &testcontrol.Server{
		DERPMap:        integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1"),
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: "example.ts.net",
		RequireAuth:    true,
		Logf:           logger.Discard,
	}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)
	return control, control.HTTPTestServer.URL
}

// startPeer runs a device in the tailnet with an echo service on port 7.
func startPeer(ctx context.Context, t *testing.T, control *testcontrol.Server, controlURL string) {
	t.Helper()
	srv := &tsnet.Server{
		Dir:        filepath.Join(t.TempDir(), "peer"),
		Hostname:   "nas",
		ControlURL: controlURL,
		Ephemeral:  true,
		UserLogf:   logger.Discard,
	}
	t.Cleanup(func() { srv.Close() })
	if err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	lc, err := srv.LocalClient()
	if err != nil {
		t.Fatal(err)
	}
	// Approve the device's login link as it appears, until it runs.
	w, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	for {
		n, err := w.Next()
		if err != nil {
			t.Fatal(err)
		}
		if n.State != nil && *n.State == ipn.Running {
			break
		}
		if n.State != nil && *n.State == ipn.NeedsLogin {
			if err := lc.StartLoginInteractive(ctx); err != nil {
				t.Fatal(err)
			}
		}
		if n.BrowseToURL != nil {
			control.CompleteAuth(*n.BrowseToURL)
		}
	}
	ln, err := srv.Listen("tcp", ":7")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
}

// waitParkedIn returns once a goroutine is blocked in state (such as
// "[select") inside fn.
func waitParkedIn(state, fn string) {
	for !parkedIn(state, fn) {
		runtime.Gosched()
	}
}

func parkedIn(state, fn string) bool {
	buf := make([]byte, 1<<20)
	n := runtime.Stack(buf, true)
	for _, g := range strings.Split(string(buf[:n]), "\n\n") {
		if strings.Contains(g, state) && strings.Contains(g, fn) {
			return true
		}
	}
	return false
}

func serve(t *testing.T, g *Gateway) string {
	sock := filepath.Join(t.TempDir(), "g.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go g.Serve(ln)
	return sock
}

func request(t *testing.T, sock string, req Request) (net.Conn, Reply) {
	t.Helper()
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	req.Token = token
	if err := WriteFrame(c, MaxSocketFrame, req); err != nil {
		t.Fatal(err)
	}
	var reply Reply
	if err := ReadFrame(c, MaxSocketFrame, &reply); err != nil {
		t.Fatal(err)
	}
	return c, reply
}

func TestLoginLinkThenRestoreFromSavedStateAndDialPeers(t *testing.T) {
	ctx := t.Context()
	control, controlURL := startControl(t)
	startPeer(ctx, t, control, controlURL)

	o := newOwner(t, controlURL)
	sock := serve(t, o.g)

	// A new node waits for a tailnet admin to open its login link.
	o.g.HandlePort(PortMessage{Type: "start", GroupID: "grp", Epoch: 1, Hostname: "comma-grp"})
	pending := o.statusFor(ctx, 1, "needs_login")
	if _, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 1, Host: "nas", Port: 7}); reply.Code != "tailnet_needs_login" {
		t.Fatalf("dial before approval: %+v", reply)
	}
	if !control.CompleteAuth(pending.AuthURL) {
		t.Fatalf("control does not know %s", pending.AuthURL)
	}
	running := o.statusFor(ctx, 1, "running")
	if running.NodeName == "" || len(running.SelfIPs) == 0 {
		t.Fatalf("running status lacks identity: %+v", running)
	}

	conn, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 1, Host: "nas", Port: 7, TimeoutMS: 30000})
	if !reply.OK || !strings.HasPrefix(reply.Peer, "nas") {
		t.Fatalf("dial: %+v", reply)
	}
	if _, err := conn.Write([]byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || line != "ping\n" {
		t.Fatalf("echo: %q %v", line, err)
	}
	conn.Close()

	if _, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 1, Host: "127.0.0.1", Port: 7}); reply.Code != "tailnet_destination_not_allowed" {
		t.Fatalf("dial outside the tailnet: %+v", reply)
	}
	if _, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 0, Host: "nas", Port: 7}); reply.Code != "tailnet_not_running" {
		t.Fatalf("dial with a stale epoch: %+v", reply)
	}
	if _, reply := request(t, sock, Request{Op: "peers", GroupID: "grp", Epoch: 1}); !reply.OK || len(reply.Peers) != 1 || reply.Peers[0].Name != "nas" {
		t.Fatalf("peers: %+v", reply)
	}

	// Open connections are bounded per node; closing one frees its slot.
	var conns []net.Conn
	for range maxRequests {
		c, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 1, Host: "nas", Port: 7, TimeoutMS: 30000})
		if !reply.OK {
			t.Fatalf("dial %d: %+v", len(conns), reply)
		}
		conns = append(conns, c)
	}
	if _, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 1, Host: "nas", Port: 7}); reply.Code != "tailnet_busy" {
		t.Fatalf("dial over the limit: %+v", reply)
	}
	from := o.mark()
	conns[0].Close()
	o.awaitSince(ctx, from, func(f any) bool { a, ok := f.(Activity); return ok && a.Conns == maxRequests-1 })
	c, reply := request(t, sock, Request{Op: "dial", GroupID: "grp", Epoch: 1, Host: "nas", Port: 7, TimeoutMS: 30000})
	if !reply.OK {
		t.Fatalf("dial after a close: %+v", reply)
	}
	for _, c := range append(conns[1:], c) {
		c.Close()
	}

	// The next owner restores the saved state: same node, no new approval.
	o.g.HandlePort(PortMessage{Type: "stop", GroupID: "grp", Epoch: 1})
	o.await(ctx, func(f any) bool { s, ok := f.(Stopped); return ok && s.Epoch == 1 })
	o.mu.Lock()
	saved := o.state[1]
	o.mu.Unlock()
	// The owner's dial can reach the socket before its start reaches the
	// port: it waits for that start.
	early := make(chan Reply, 1)
	go func() {
		c, err := net.Dial("unix", sock)
		if err != nil {
			early <- Reply{Message: err.Error()}
			return
		}
		defer c.Close()
		var r Reply
		if err := WriteFrame(c, MaxSocketFrame, Request{Token: token, Op: "dial", GroupID: "grp", Epoch: 2, Host: "nas", Port: 7, TimeoutMS: 30000}); err == nil {
			ReadFrame(c, MaxSocketFrame, &r)
		}
		early <- r
	}()
	waitParkedIn("[select", "(*Gateway).node(")
	o.g.HandlePort(PortMessage{Type: "start", GroupID: "grp", Epoch: 2, Hostname: "comma-grp", State: saved})
	if r := <-early; !r.OK {
		t.Fatalf("dial sent before its start: %+v", r)
	}
	restored := o.statusFor(ctx, 2, "running")
	if restored.NodeName != running.NodeName {
		t.Fatalf("restored node %q, want %q", restored.NodeName, running.NodeName)
	}
	o.mu.Lock()
	for _, f := range o.frames {
		if s, ok := f.(Status); ok && s.Epoch == 2 && s.Status == "needs_login" && s.AuthURL != "" {
			t.Errorf("restored node asked for a new login: %+v", s)
		}
	}
	o.mu.Unlock()
}

func TestPeersPagesFitOneFrame(t *testing.T) {
	var subnets []string
	for i := range 600 {
		subnets = append(subnets, netip.PrefixFrom(netip.AddrFrom4([4]byte{10, byte(i >> 8), byte(i), 0}), 24).String())
	}
	var peers []*ipnstate.PeerStatus
	for i := range 150 {
		p := &ipnstate.PeerStatus{
			HostName:      strings.Repeat("h", 300),
			DNSName:       fmt.Sprintf("%s-%03d.example.ts.net.", strings.Repeat("d", 60), i),
			TailscaleIPs:  []netip.Addr{netip.AddrFrom4([4]byte{100, 64, byte(i >> 8), byte(i)})},
			PrimaryRoutes: routes(subnets[:i%40]...),
		}
		if i == 7 {
			// One subnet router alone exceeds a page.
			p.PrimaryRoutes = routes(subnets...)
		}
		peers = append(peers, p)
	}
	st := status(peers...)

	seen := map[string]bool{}
	pages := 0
	for cursor := 0; ; {
		page, next := Peers(st, cursor)
		body, err := json.Marshal(Reply{OK: true, Peers: page, Next: next, Tailnet: strings.Repeat("t", 253)})
		if err != nil || len(body) > MaxSocketFrame || len(page) == 0 {
			t.Fatalf("page at %d: %d entries, %d bytes, %v", cursor, len(page), len(body), err)
		}
		for _, p := range page {
			if seen[p.DNSName] {
				t.Fatalf("%s listed twice", p.DNSName)
			}
			seen[p.DNSName] = true
			if want := strings.HasSuffix(p.DNSName, "-007.example.ts.net"); p.Truncated != want {
				t.Errorf("%s: truncated %v, want %v", p.DNSName, p.Truncated, want)
			}
		}
		pages++
		if next == 0 {
			break
		}
		cursor = next
	}
	if len(seen) != len(peers) || pages < 2 {
		t.Fatalf("listed %d of %d peers in %d pages", len(seen), len(peers), pages)
	}
}

func TestLogoutWaitsForAQueuedStart(t *testing.T) {
	ctx := t.Context()
	control, controlURL := startControl(t)
	o := newOwner(t, controlURL)
	o.g.HandlePort(PortMessage{Type: "start", GroupID: "grp", Epoch: 1, Hostname: "comma-grp"})
	pending := o.statusFor(ctx, 1, "needs_login")
	control.CompleteAuth(pending.AuthURL)
	o.statusFor(ctx, 1, "running")
	o.g.HandlePort(PortMessage{Type: "stop", GroupID: "grp", Epoch: 1})
	o.await(ctx, func(f any) bool { s, ok := f.(Stopped); return ok && s.Epoch == 1 })
	o.mu.Lock()
	saved := o.state[1]
	o.mu.Unlock()

	// Every start slot is taken: the restore waits for one while its logout
	// arrives, as when a Group is disconnected while other nodes start.
	for range startSlots {
		o.g.slots <- struct{}{}
	}
	o.g.HandlePort(PortMessage{Type: "start", GroupID: "grp", Epoch: 2, Hostname: "comma-grp", State: saved})
	o.g.HandlePort(PortMessage{Type: "stop", GroupID: "grp", Epoch: 2, Logout: true})
	stopped := func(f any) bool { s, ok := f.(Stopped); return ok && s.Epoch == 2 }
	for !parkedIn("[chan receive", "(*node).close") {
		o.mu.Lock()
		early := slices.ContainsFunc(o.frames, stopped)
		o.mu.Unlock()
		if early {
			t.Fatal("the node stopped before its queued start ran")
		}
		runtime.Gosched()
	}
	for range startSlots {
		<-o.g.slots
	}
	if s := o.await(ctx, stopped).(Stopped); !s.LoggedOut {
		t.Fatalf("the restored node did not log out: %+v", s)
	}
}

func TestNodeStopsWhenTheOwnerCannotSaveItsState(t *testing.T) {
	ctx := t.Context()
	_, controlURL := startControl(t)
	o := newOwner(t, controlURL)
	o.refuse = true

	o.g.HandlePort(PortMessage{Type: "start", GroupID: "grp", Epoch: 1, Hostname: "comma-grp"})
	o.await(ctx, func(f any) bool {
		s, ok := f.(Status)
		return ok && s.Code == "tailnet_state_not_saved"
	})
	o.await(ctx, func(f any) bool { s, ok := f.(Stopped); return ok && s.Epoch == 1 })
}
