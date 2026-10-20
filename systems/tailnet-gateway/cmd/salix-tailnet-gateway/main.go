// Command salix-tailnet-gateway connects the Agent Groups that one Salix node
// owns to their tailnets.
//
// SalixAgent.Tailnet.Gateway starts it as an Erlang port with 4-byte length
// framing. The first frame on stdin is the configuration. The gateway listens
// on the configured Unix socket and writes one {"type":"ready"} frame, then
// applies start, stop and persisted frames. It exits when stdin closes, so it
// never outlives the node that started it.
package main

import (
	"errors"
	"log"
	"net"
	"os"
	"sync"

	gateway "github.com/comma/salix-tailnet-gateway"
	"tailscale.com/envknob"
)

type config struct {
	Socket     string `json:"socket"`
	Token      string `json:"token"`
	Dir        string `json:"dir"`
	ControlURL string `json:"control_url"`
}

func main() {
	log.SetPrefix("salix-tailnet-gateway: ")
	log.SetFlags(0)
	// Node logs stay on this host; nothing is uploaded to Tailscale.
	envknob.SetNoLogsNoSupport()

	var cfg config
	if err := gateway.ReadFrame(os.Stdin, gateway.MaxPortFrame, &cfg); err != nil {
		log.Fatalf("configuration: %v", err)
	}
	var mu sync.Mutex
	emit := func(v any) error {
		mu.Lock()
		defer mu.Unlock()
		return gateway.WriteFrame(os.Stdout, gateway.MaxPortFrame, v)
	}
	var logf func(string, ...any)
	if os.Getenv("SALIX_TAILNET_VERBOSE") != "" {
		logf = log.Printf
	}
	g, err := gateway.New(gateway.Config{
		Token:      cfg.Token,
		Dir:        cfg.Dir,
		ControlURL: cfg.ControlURL,
		Emit:       emit,
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
		if err := g.Serve(ln); !errors.Is(err, net.ErrClosed) {
			log.Printf("serve: %v", err)
		}
	}()
	if err := emit(map[string]string{"type": "ready"}); err != nil {
		log.Fatal(err)
	}
	for {
		var m gateway.PortMessage
		if err := gateway.ReadFrame(os.Stdin, gateway.MaxPortFrame, &m); err != nil {
			// The port closes stdin when the node stops or restarts the
			// gateway. Close without logging out: the next owner restores
			// the nodes from their saved state.
			ln.Close()
			g.Close()
			os.Remove(cfg.Socket)
			os.Exit(0)
		}
		g.HandlePort(m)
	}
}
