package gateway

import (
	"bufio"
	"context"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/comma/salix-tailcat-gateway/internal/devderp"
	"github.com/comma/salix-tailcat-gateway/internal/testpeer"
	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

const token = "test-token"

func echoServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return ln.Addr().String()
}

func startGateway(t *testing.T, cfg Config) (*Gateway, string) {
	t.Helper()
	cfg.Token = token
	g, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	sock := filepath.Join(t.TempDir(), "g.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	go g.Serve(ln)
	t.Cleanup(func() { ln.Close(); g.Close() })
	return g, sock
}

func dial(t *testing.T, sock string, req Request) (net.Conn, Reply) {
	t.Helper()
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	if err := WriteFrame(c, req); err != nil {
		t.Fatal(err)
	}
	var reply Reply
	if err := ReadFrame(c, &reply); err != nil {
		t.Fatal(err)
	}
	return c, reply
}

func TestEachDialUsesANewEphemeralClient(t *testing.T) {
	peer, err := testpeer.Start(t.Logf, 22, echoServer(t))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	g, sock := startGateway(t, Config{DERPMapURL: peer.Relay.MapURL, Logf: t.Logf})
	req := Request{Token: token, Address: string(peer.Address), Port: 22}
	ci, err := tailcat.ParseAddr(peer.Address)
	if err != nil {
		t.Fatal(err)
	}
	serverKey := ci.ServerPublic.String()

	var conns []net.Conn
	for i, line := range []string{"first\n", "second\n"} {
		c, reply := dial(t, sock, req)
		if !reply.OK {
			t.Fatalf("dial %d: %+v", i, reply)
		}
		if reply.ServerNodeKey != serverKey {
			t.Fatalf("server key %q, want %q", reply.ServerNodeKey, serverKey)
		}
		c.SetDeadline(time.Now().Add(10 * time.Second))
		io.WriteString(c, line)
		got, err := bufio.NewReader(c).ReadString('\n')
		if err != nil || got != line {
			t.Fatalf("echo %d: %q, %v", i, got, err)
		}
		conns = append(conns, c)
	}
	if n := g.Conns(); n != 2 {
		t.Fatalf("open connections = %d, want 2", n)
	}
	// The server saw two different client node keys.
	if r := peer.Remotes(); len(r) != 2 || r[0] == r[1] {
		t.Fatalf("client tunnel addresses %v, want two different ones", r)
	}
	// A closed connection closes its client.
	for _, c := range conns {
		c.Close()
	}
	deadline := time.Now().Add(15 * time.Second)
	for g.Conns() != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("open connections = %d after close, want 0", g.Conns())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestDialCannotReachAServerThatListsClients(t *testing.T) {
	peer, err := testpeer.Start(t.Logf, 22, echoServer(t), key.NewNode().Public())
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	g, sock := startGateway(t, Config{DERPMapURL: peer.Relay.MapURL, Logf: t.Logf})

	_, reply := dial(t, sock, Request{Token: token, Address: string(peer.Address), Port: 22})
	if reply.OK || reply.Code != "tailcat_unreachable" || !strings.Contains(reply.Message, "--allow") {
		t.Fatalf("got %+v, want tailcat_unreachable that names --allow", reply)
	}
	if n := g.Conns(); n != 0 {
		t.Fatalf("failed client stayed open: %d", n)
	}
}

func TestDialRejectsClosedPortAndBadToken(t *testing.T) {
	peer, err := testpeer.Start(t.Logf, 22, echoServer(t))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	_, sock := startGateway(t, Config{DERPMapURL: peer.Relay.MapURL, Logf: t.Logf})
	_, reply := dial(t, sock, Request{Token: token, Address: string(peer.Address), Port: 2222, TimeoutMS: 5000})
	if reply.Code != "tailcat_connect_failed" {
		t.Fatalf("closed port: %+v", reply)
	}
	_, reply = dial(t, sock, Request{Token: "wrong", Address: string(peer.Address), Port: 22})
	if reply.OK || reply.Code != "tailcat_unavailable" {
		t.Fatalf("bad token: %+v", reply)
	}
}

func TestCanonicalKeepsRelaysInTheTrustedMap(t *testing.T) {
	relay, err := devderp.Start(t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	ctx := context.Background()
	server := key.NewNode().Public()
	disco := key.NewDisco().Public()
	base := tailcat.ConnInfo{
		ServerPublic:      tailcat.NodePublic{NodePublic: server},
		ServerDiscoPublic: tailcat.DiscoPublic{DiscoPublic: disco},
	}
	node := func(host, ip string, port int) *tailcfg.DERPRegion {
		return &tailcfg.DERPRegion{Nodes: []*tailcfg.DERPNode{{HostName: host, IPv4: ip, DERPPort: port, InsecureForTests: true}}}
	}
	cases := []struct {
		name    string
		region  tailcfg.DERPRegionID
		regions []*tailcfg.DERPRegion
		code    string
	}{
		{name: "short trusted", region: 900},
		{name: "embedded trusted host, other IP and port", regions: []*tailcfg.DERPRegion{node("derp.dev.invalid", "10.0.0.1", 8080)}},
		{name: "short unknown region", region: 7, code: "tailcat_blocked_relay"},
		{name: "auto region", region: -1, code: "tailcat_blocked_relay"},
		{name: "embedded private relay", regions: []*tailcfg.DERPRegion{node("metadata.internal", "169.254.169.254", 80)}, code: "tailcat_blocked_relay"},
		{name: "embedded IP-only relay", regions: []*tailcfg.DERPRegion{node("", "10.0.0.1", 443)}, code: "tailcat_blocked_relay"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ci := base
			ci.RegionID = tc.region
			ci.Region = tc.regions
			addr, got, err := Canonical(ctx, string(ci.Addr()), relay.MapURL)
			if tc.code != "" {
				e, ok := err.(*Error)
				if !ok || e.Code != tc.code {
					t.Fatalf("err = %v, want %s", err, tc.code)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			out, err := tailcat.ParseAddr(addr)
			if err != nil {
				t.Fatal(err)
			}
			if got != server || out.RegionID != 900 || len(out.Region) != 0 {
				t.Fatalf("canonical %+v for %v", out, got)
			}
		})
	}
	if _, _, err := Canonical(ctx, "tcnot-an-address", relay.MapURL); err == nil || err.(*Error).Code != "tailcat_invalid_address" {
		t.Fatalf("garbage: %v", err)
	}
	// An address pasted with a dotted suffix is refused before any DNS lookup.
	leak := "x." + string(base.Addr()) + ".example.com"
	if _, _, err := Resolve(ctx, leak, relay.MapURL); err == nil || !strings.Contains(err.Error(), "DNS label") {
		t.Fatalf("address as a DNS label: %v", err)
	}
}
