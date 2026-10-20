// Command tailnet-testpeer runs a tailnet for the Salix tailnet tests: a
// local DERP relay and STUN server, a test coordination server that requires
// login approval, and one device named "nas". It is not part of the release
// image.
//
// The device forwards its port 22 to --target, echoes on port 7 and answers
// HTTP on port 80 with a JSON object naming itself and the path. The
// command prints one JSON line with the coordination server URL, then reads
// commands on stdin, one per line, and answers each with one JSON line:
//
//	approve <login URL>   approve a node's login link
//
// It exits when stdin closes.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/netns"
	"tailscale.com/net/stun"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func main() {
	target := flag.String("target", "", "host:port that receives the device's port 22")
	flag.Parse()
	logf := logger.Discard
	if os.Getenv("SALIX_TAILNET_VERBOSE") != "" {
		logf = log.Printf
	}
	netns.SetEnabled(false)

	control := &testcontrol.Server{
		DERPMap:        startDERP(logf),
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: "example.ts.net",
		RequireAuth:    true,
		AllOnline:      true,
		Logf:           logf,
	}
	srv := httptest.NewUnstartedServer(control)
	control.HTTPTestServer = srv
	srv.Start()
	defer srv.Close()

	dir, err := os.MkdirTemp("", "tailnet-testpeer-")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(dir)
	device := &tsnet.Server{
		Dir:        filepath.Join(dir, "nas"),
		Hostname:   "nas",
		ControlURL: srv.URL,
		Ephemeral:  true,
		Logf:       logf,
		UserLogf:   logger.Discard,
	}
	defer device.Close()
	if err := up(device, control); err != nil {
		log.Fatal(err)
	}
	if *target != "" {
		serve(device, ":22", func(c net.Conn) {
			defer c.Close()
			d, err := net.Dial("tcp", *target)
			if err != nil {
				return
			}
			defer d.Close()
			go io.Copy(d, c)
			io.Copy(c, d)
		})
	}
	serve(device, ":7", func(c net.Conn) { io.Copy(c, c); c.Close() })
	web, err := device.Listen("tcp", ":80")
	if err != nil {
		log.Fatal(err)
	}
	go http.Serve(web, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"device": "nas", "path": r.URL.Path})
	}))

	out := json.NewEncoder(os.Stdout)
	out.Encode(map[string]string{"control_url": srv.URL})
	lines := bufio.NewScanner(os.Stdin)
	for lines.Scan() {
		cmd, arg, _ := strings.Cut(strings.TrimSpace(lines.Text()), " ")
		switch cmd {
		case "approve":
			out.Encode(map[string]bool{"ok": control.CompleteAuth(arg)})
		default:
			out.Encode(map[string]bool{"ok": false})
		}
	}
}

func up(device *tsnet.Server, control *testcontrol.Server) error {
	if err := device.Start(); err != nil {
		return err
	}
	lc, err := device.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		st, err := lc.StatusWithoutPeers(ctx)
		if err != nil {
			return err
		}
		if st.BackendState == "Running" {
			return nil
		}
		if st.AuthURL != "" {
			control.CompleteAuth(st.AuthURL)
		}
		time.Sleep(50 * time.Millisecond)
	}
	return ctx.Err()
}

func serve(device *tsnet.Server, addr string, handle func(net.Conn)) {
	ln, err := device.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go handle(c)
		}
	}()
}

// startDERP runs a DERP relay and a STUN server on 127.0.0.1 and returns a
// map that holds only them.
func startDERP(logf logger.Logf) *tailcfg.DERPMap {
	d := derpserver.New(key.NewNode(), logf)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	derpSrv := httptest.NewUnstartedServer(derpserver.Handler(d))
	derpSrv.Listener = ln
	derpSrv.Config.ErrorLog = logger.StdLogger(logf)
	derpSrv.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	derpSrv.StartTLS()

	uln, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		var buf [1500]byte
		for {
			n, src, err := uln.ReadFromUDPAddrPort(buf[:])
			if err != nil {
				return
			}
			if txid, err := stun.ParseBindingRequest(buf[:n]); err == nil {
				uln.WriteToUDPAddrPort(stun.Response(txid, src), src)
			}
		}
	}()
	return &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
		900: {
			RegionID:   900,
			RegionCode: "dev",
			Nodes: []*tailcfg.DERPNode{{
				Name:             "900a",
				RegionID:         900,
				HostName:         "127.0.0.1",
				IPv4:             "127.0.0.1",
				IPv6:             "none",
				STUNPort:         uln.LocalAddr().(*net.UDPAddr).Port,
				DERPPort:         ln.Addr().(*net.TCPAddr).Port,
				InsecureForTests: true,
			}},
		},
	}}
}
