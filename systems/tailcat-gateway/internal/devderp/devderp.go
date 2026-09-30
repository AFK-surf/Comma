// Package devderp runs a local DERP relay, STUN server and DERP map for
// tests. It follows runDevDERP in tailcat's cmd/tailcat (BSD-3-Clause,
// Tailscale Inc & contributors).
package devderp

import (
	"crypto/tls"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stun"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// Relay is a running local relay.
type Relay struct {
	Region *tailcfg.DERPRegion
	// MapURL serves a DERP map that holds only Region.
	MapURL string

	derp *derpserver.Server
	srvs []*httptest.Server
	stun net.PacketConn
}

// Start starts a relay on 127.0.0.1.
func Start(logf logger.Logf) (*Relay, error) {
	d := derpserver.New(key.NewNode(), logf)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	derpSrv := httptest.NewUnstartedServer(derpserver.Handler(d))
	derpSrv.Listener = ln
	derpSrv.Config.ErrorLog = logger.StdLogger(logf)
	derpSrv.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	derpSrv.StartTLS()

	// Without STUN, netcheck waits about 3 seconds for UDP probes.
	uln, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		derpSrv.Close()
		return nil, err
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

	region := &tailcfg.DERPRegion{
		RegionID:   900,
		RegionCode: "dev",
		Nodes: []*tailcfg.DERPNode{{
			Name:             "900a",
			RegionID:         900,
			HostName:         "derp.dev.invalid",
			IPv4:             "127.0.0.1",
			IPv6:             "none",
			STUNPort:         uln.LocalAddr().(*net.UDPAddr).Port,
			DERPPort:         ln.Addr().(*net.TCPAddr).Port,
			InsecureForTests: true,
		}},
	}
	dm, _ := json.Marshal(&tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{900: region}})
	mapSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(dm)
	}))
	return &Relay{
		Region: region,
		MapURL: mapSrv.URL,
		derp:   d,
		srvs:   []*httptest.Server{derpSrv, mapSrv},
		stun:   uln,
	}, nil
}

// Close stops the relay.
func (r *Relay) Close() {
	for _, s := range r.srvs {
		s.Close()
	}
	r.stun.Close()
	r.derp.Close()
}
