package gateway

import (
	"context"
	"net"
	"strings"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

// Canonical checks a tailcat address and returns the address to dial and the
// server's node key.
//
// The address comes from an Agent, so it is untrusted. A resolved address can
// embed DERP nodes with any host, IP, port and TLS setting; dialing them would
// open TCP, TLS and STUN traffic to hosts that the SSH destination policy
// refuses. So relays come only from the trusted DERP map:
//
//   - A short address (region ID only) must name a region in the map.
//   - An embedded region is accepted only when every embedded node has a host
//     name that belongs to one region of the map. Its IPs, ports and TLS
//     settings are discarded in favor of the map's.
//
// The result is always a short address that names the trusted region. The
// client expands it from the same map.
func Canonical(ctx context.Context, address, derpMapURL string) (tailcat.Addr, key.NodePublic, error) {
	var zero key.NodePublic
	ci, err := tailcat.ParseAddr(tailcat.Addr(strings.TrimSpace(address)))
	if err != nil {
		return "", zero, fail("tailcat_invalid_address", "The Tailcat address could not be parsed.")
	}
	return canonical(ctx, ci, derpMapURL)
}

// Resolve accepts a tailcat address or a DNS name whose "tailcat=" TXT record
// holds one, like the tailcat CLI, and returns Canonical's result.
func Resolve(ctx context.Context, target, derpMapURL string) (tailcat.Addr, key.NodePublic, error) {
	target = strings.TrimSpace(target)
	if _, err := tailcat.ParseAddr(tailcat.Addr(target)); err == nil || !strings.Contains(target, ".") {
		return Canonical(ctx, target, derpMapURL)
	}
	name := strings.TrimSuffix(target, ".")
	for label := range strings.SplitSeq(name, ".") {
		// A pasted address with a dotted suffix must not leak into DNS.
		if _, err := tailcat.ParseAddr(tailcat.Addr(label)); err == nil {
			return "", key.NodePublic{}, fail("tailcat_invalid_address",
				"The name contains a Tailcat address as a DNS label; pass the address alone.")
		}
	}
	lookup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	txts, err := net.DefaultResolver.LookupTXT(lookup, name)
	if err != nil {
		return "", key.NodePublic{}, fail("tailcat_invalid_address", "The TXT lookup for %s failed.", name)
	}
	for _, txt := range txts {
		if addr, ok := strings.CutPrefix(txt, "tailcat="); ok {
			return Canonical(ctx, addr, derpMapURL)
		}
	}
	return "", key.NodePublic{}, fail("tailcat_invalid_address", "%s has no \"tailcat=\" TXT record.", name)
}

func canonical(ctx context.Context, ci tailcat.ConnInfo, derpMapURL string) (tailcat.Addr, key.NodePublic, error) {
	var zero key.NodePublic
	if ci.ServerPublic.IsZero() || ci.ServerDiscoPublic.IsZero() {
		return "", zero, fail("tailcat_invalid_address",
			"The Tailcat address has no server key or is from a tailcat server older than v0.5.")
	}
	dm, err := tailcat.FetchDERPMap(ctx, tailcat.DERPMapURL(derpMapURL))
	if err != nil {
		return "", zero, fail("tailcat_relay_unavailable", "The trusted DERP map could not be loaded.")
	}
	region, ok := trustedRegion(ci, dm)
	if !ok {
		return "", zero, fail("tailcat_blocked_relay",
			"The Tailcat address names a DERP relay that is not in the trusted DERP map. Ask the user for an address from a tailcat server that uses the default relays.")
	}
	out := tailcat.ConnInfo{
		ServerPublic:      ci.ServerPublic,
		ServerDiscoPublic: ci.ServerDiscoPublic,
		PresharedKey:      ci.PresharedKey,
		RegionID:          region,
	}
	return out.Addr(), ci.ServerPublic.NodePublic, nil
}

func trustedRegion(ci tailcat.ConnInfo, dm *tailcfg.DERPMap) (tailcfg.DERPRegionID, bool) {
	if len(ci.Region) == 0 {
		// -1 asks the client to probe every region; servers use it, clients
		// must not.
		_, ok := dm.Regions[ci.RegionID]
		return ci.RegionID, ok && ci.RegionID > 0
	}
	var found tailcfg.DERPRegionID
	for _, r := range ci.Region {
		if len(r.Nodes) == 0 {
			return 0, false
		}
		for _, n := range r.Nodes {
			id := regionOfHost(dm, n.HostName)
			if id == 0 || (found != 0 && id != found) {
				return 0, false
			}
			found = id
		}
	}
	return found, found != 0
}

func regionOfHost(dm *tailcfg.DERPMap, host string) tailcfg.DERPRegionID {
	if host == "" {
		return 0
	}
	for id, r := range dm.Regions {
		for _, n := range r.Nodes {
			if strings.EqualFold(n.HostName, host) {
				return id
			}
		}
	}
	return 0
}
