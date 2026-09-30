// Command tailcat-testpeer runs a Tailcat server behind a local relay for the
// Salix SSH tests. It is not part of the release image.
//
// It forwards --port on the Tailcat server to --target, or with
// --ssh-authorized-keys serves port 22 with tailcat's built-in SSH server. It
// prints one JSON line with the address, the DERP map URL and the server's
// node key, and exits when stdin closes.
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"os"

	"github.com/comma/salix-tailcat-gateway/internal/testpeer"
	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
)

func main() {
	port := flag.Uint("port", 22, "Tailcat server port to serve")
	target := flag.String("target", "", "host:port that receives the connections")
	allow := flag.String("allow", "", "if set, the only client node key the server admits")
	sshKeys := flag.String("ssh-authorized-keys", "", "if set, serve port 22 with the built-in SSH server for this public key line")
	flag.Parse()

	var keys []key.NodePublic
	if *allow != "" {
		var k key.NodePublic
		if err := k.UnmarshalText([]byte(*allow)); err != nil {
			log.Fatalf("--allow: %v", err)
		}
		keys = append(keys, k)
	}
	logf := func(string, ...any) {}
	if os.Getenv("SALIX_TAILCAT_VERBOSE") != "" {
		logf = log.Printf
	}
	var peer *testpeer.Peer
	var err error
	if *sshKeys != "" {
		peer, err = testpeer.StartSSH(logf, []string{*sshKeys})
	} else {
		peer, err = testpeer.Start(logf, uint16(*port), *target, keys...)
	}
	if err != nil {
		log.Fatal(err)
	}
	ci, err := tailcat.ParseAddr(peer.Address)
	if err != nil {
		log.Fatal(err)
	}
	json.NewEncoder(os.Stdout).Encode(map[string]string{
		"address":      string(peer.Address),
		"derp_map_url": peer.Relay.MapURL,
		"node_key":     ci.ServerPublic.String(),
	})
	io.Copy(io.Discard, os.Stdin)
	peer.Close()
}
