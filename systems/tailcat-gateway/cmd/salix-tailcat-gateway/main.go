// Command salix-tailcat-gateway is the Tailcat gateway for one Salix node.
//
// SalixAgent.Tailcat.Gateway starts it as an Erlang port with 4-byte length
// framing. The first frame on stdin is the configuration. The gateway listens
// on the configured Unix socket and writes one {"type":"ready"} frame. It exits
// when stdin closes, so it never outlives the node that started it.
package main

import (
	"errors"
	"io"
	"log"
	"net"
	"os"

	gateway "github.com/comma/salix-tailcat-gateway"
)

type config struct {
	Socket     string `json:"socket"`
	Token      string `json:"token"`
	DERPMapURL string `json:"derp_map_url"`
}

func main() {
	log.SetPrefix("salix-tailcat-gateway: ")
	log.SetFlags(0)
	var cfg config
	if err := gateway.ReadFrame(os.Stdin, &cfg); err != nil {
		log.Fatalf("configuration: %v", err)
	}
	var logf func(string, ...any)
	if os.Getenv("SALIX_TAILCAT_VERBOSE") != "" {
		logf = log.Printf
	}
	g, err := gateway.New(gateway.Config{
		Token:      cfg.Token,
		DERPMapURL: cfg.DERPMapURL,
		Logf:       logf,
	})
	if err != nil {
		log.Fatal(err)
	}
	os.Remove(cfg.Socket)
	ln, err := net.Listen("unix", cfg.Socket)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	if err := os.Chmod(cfg.Socket, 0o600); err != nil {
		log.Fatalf("chmod: %v", err)
	}
	go func() {
		// The port closes stdin when the node stops or restarts the gateway.
		io.Copy(io.Discard, os.Stdin)
		ln.Close()
		g.Close()
		os.Remove(cfg.Socket)
		os.Exit(0)
	}()
	if err := gateway.WriteFrame(os.Stdout, map[string]string{"type": "ready"}); err != nil {
		log.Fatal(err)
	}
	if err := g.Serve(ln); !errors.Is(err, net.ErrClosed) {
		log.Printf("serve: %v", err)
	}
	select {} // the stdin watcher exits the process
}
