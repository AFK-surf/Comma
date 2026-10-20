package main

import (
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
)

//go:embed screen_stream_demo.html
var screenStreamDemoPage []byte

// runScreenStreamDemo serves a local viewer page that drives the same
// screen_stream method the Server calls, for development without a Server.
func runScreenStreamDemo(args []string) error {
	flags := flag.NewFlagSet("screen-stream-demo", flag.ContinueOnError)
	listen := flags.String("listen", "127.0.0.1:8787", "viewer listen address")
	helperApp := flags.String("helper-app", defaultComputerUseHelperAppPath(), "Comma Computer Use.app path")
	socketPath := flags.String("socket", defaultComputerUseSocketPath(), "computer_use daemon socket path")
	if err := flags.Parse(args); err != nil {
		return err
	}
	c := &connector{cfg: config{computerUseHelperApp: *helperApp, computerUseSocketPath: *socketPath}}
	defer c.shutdownComputerUseDaemon()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(screenStreamDemoPage)
	})
	mux.HandleFunc("POST /screen_stream", func(w http.ResponseWriter, r *http.Request) {
		var params map[string]any
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&params); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		// A viewer served from another local origin (Storybook) may drive this endpoint.
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(c.methodScreenStream(r.Context(), params))
	})
	fmt.Printf("screen stream viewer: http://%s\n", *listen)
	return http.ListenAndServe(*listen, mux)
}
