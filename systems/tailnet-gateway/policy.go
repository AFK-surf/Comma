package gateway

import (
	"cmp"
	"encoding/json"
	"net/netip"
	"slices"
	"strings"

	"tailscale.com/ipn/ipnstate"
)

// Target is a checked tailnet destination.
type Target struct {
	Addr netip.Addr
	// Peer is the DNS name of the peer that owns the address or the subnet
	// route that contains it.
	Peer string
}

// Resolve checks that host names a destination inside the tailnet and returns
// the address to dial.
//
// The host comes from an Agent, so it is untrusted. It is resolved only from
// the node's own netmap, never from DNS. An address is allowed when it is a
// peer's Tailscale address, or, with acceptRoutes, when a peer's approved
// subnet route contains it. Exit-node routes (/0) never count: the gateway
// must not reach the internet or the Pod network through the tailnet.
func Resolve(st *ipnstate.Status, host string, acceptRoutes bool) (Target, error) {
	host = strings.ToLower(strings.TrimSuffix(strings.Trim(strings.TrimSpace(host), "[]"), "."))
	if host == "" {
		return Target{}, fail("tailnet_host_unknown", "The host is empty.")
	}
	if st == nil {
		return Target{}, fail("tailnet_starting", "The tailnet node has no network map yet. Retry shortly.")
	}
	peers := sortedPeers(st)

	if addr, err := netip.ParseAddr(host); err == nil {
		addr = addr.Unmap()
		for _, p := range peers {
			if slices.Contains(p.TailscaleIPs, addr) {
				return Target{Addr: addr, Peer: peerName(p)}, nil
			}
		}
		if acceptRoutes {
			for _, p := range peers {
				if p.PrimaryRoutes == nil {
					continue
				}
				for _, route := range p.PrimaryRoutes.All() {
					if route.Bits() > 0 && route.Contains(addr) {
						return Target{Addr: addr, Peer: peerName(p)}, nil
					}
				}
			}
		}
		return Target{}, fail("tailnet_destination_not_allowed",
			"%s is not a peer in the tailnet or inside an approved subnet route. Call tailnet.peers to list reachable devices.", host)
	}

	var matches []*ipnstate.PeerStatus
	for _, p := range peers {
		full := strings.ToLower(strings.TrimSuffix(p.DNSName, "."))
		short, _, _ := strings.Cut(full, ".")
		if host == full || host == short || (full == "" && host == strings.ToLower(p.HostName)) {
			matches = append(matches, p)
		}
	}
	switch len(matches) {
	case 0:
		return Target{}, fail("tailnet_host_unknown",
			"No peer in the tailnet is named %s. Call tailnet.peers to list reachable devices.", host)
	case 1:
	default:
		return Target{}, fail("tailnet_host_unknown",
			"%d peers match %s. Use the full MagicDNS name or an address.", len(matches), host)
	}
	p := matches[0]
	addrs := slices.Clone(p.TailscaleIPs)
	// Prefer IPv4: some services listen only on it.
	slices.SortStableFunc(addrs, func(a, b netip.Addr) int { return cmp.Compare(a.BitLen(), b.BitLen()) })
	if len(addrs) == 0 {
		return Target{}, fail("tailnet_host_unknown", "The peer %s has no Tailscale address.", host)
	}
	return Target{Addr: addrs[0], Peer: peerName(p)}, nil
}

func sortedPeers(st *ipnstate.Status) []*ipnstate.PeerStatus {
	peers := make([]*ipnstate.PeerStatus, 0, len(st.Peer))
	for _, p := range st.Peer {
		if p != nil {
			peers = append(peers, p)
		}
	}
	slices.SortFunc(peers, func(a, b *ipnstate.PeerStatus) int {
		return cmp.Or(cmp.Compare(a.DNSName, b.DNSName), cmp.Compare(a.ID, b.ID))
	})
	return peers
}

func peerName(p *ipnstate.PeerStatus) string {
	if name := strings.TrimSuffix(p.DNSName, "."); name != "" {
		return name
	}
	return p.HostName
}

// Peer is one entry of a peers reply.
type Peer struct {
	Name     string   `json:"name"`
	DNSName  string   `json:"dns_name,omitempty"`
	IPs      []string `json:"ips"`
	OS       string   `json:"os,omitempty"`
	Online   bool     `json:"online"`
	Tags     []string `json:"tags,omitempty"`
	Routes   []string `json:"routes,omitempty"`
	ExitNode bool     `json:"exit_node,omitempty"`
	// Truncated reports that some of the peer's tags or routes are left out.
	Truncated bool `json:"truncated,omitempty"`
}

const (
	// MaxPeers bounds the entries of one peers page.
	MaxPeers = 200
	// peersBudget bounds the encoded entries of one page, so the reply fits
	// in one socket frame with its other fields.
	peersBudget = MaxSocketFrame - 1024
	// maxPeerBytes bounds one encoded entry. A peer with more tags or routes
	// is listed without them.
	maxPeerBytes = 6 << 10
	maxPeerList  = 16  // addresses listed for one peer
	maxPeerText  = 255 // bytes of one name or OS
)

// Peers returns one page of peers, sorted by DNS name, and the next cursor
// (0 when there are no more). A page holds at most MaxPeers entries and
// stops before its encoded entries exceed peersBudget.
func Peers(st *ipnstate.Status, cursor int) ([]Peer, int) {
	peers := sortedPeers(st)
	if cursor < 0 || cursor >= len(peers) {
		return []Peer{}, 0
	}
	out := []Peer{}
	size := 0
	next := cursor
	for ; next < len(peers) && len(out) < MaxPeers; next++ {
		entry, n := peerEntry(peers[next])
		if size+n+1 > peersBudget {
			break
		}
		out = append(out, entry)
		size += n + 1
	}
	if next == len(peers) {
		return out, 0
	}
	return out, next
}

// peerEntry returns the peer's entry and its encoded size, at most
// maxPeerBytes.
func peerEntry(p *ipnstate.PeerStatus) (Peer, int) {
	entry := Peer{
		Name:     clip(p.HostName),
		DNSName:  clip(strings.TrimSuffix(p.DNSName, ".")),
		OS:       clip(p.OS),
		Online:   p.Online,
		ExitNode: p.ExitNodeOption,
		IPs:      []string{},
	}
	for _, ip := range p.TailscaleIPs[:min(len(p.TailscaleIPs), maxPeerList)] {
		entry.IPs = append(entry.IPs, ip.String())
	}
	if p.Tags != nil {
		entry.Tags = p.Tags.AsSlice()
	}
	if p.PrimaryRoutes != nil {
		for _, route := range p.PrimaryRoutes.All() {
			if route.Bits() > 0 {
				entry.Routes = append(entry.Routes, route.String())
			}
		}
	}
	if n := encodedSize(entry); n <= maxPeerBytes {
		return entry, n
	}
	// Clipped names and at most maxPeerList addresses always fit.
	entry.Tags, entry.Routes, entry.Truncated = nil, nil, true
	return entry, encodedSize(entry)
}

func encodedSize(v any) int {
	body, _ := json.Marshal(v)
	return len(body)
}

func clip(s string) string {
	if len(s) <= maxPeerText {
		return s
	}
	return strings.ToValidUTF8(s[:maxPeerText], "")
}
