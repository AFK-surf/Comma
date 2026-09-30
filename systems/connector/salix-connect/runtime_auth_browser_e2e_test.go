package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// TestRuntimeAuthBrowserTargetHarness is started by the Chromium E2E. It is a
// test transport around the production Compute target owner, not a second auth
// implementation. The browser supplies only its public target; this harness
// derives the same private scope that the authenticated server normally adds.
func TestRuntimeAuthBrowserTargetHarness(t *testing.T) {
	readyPath := os.Getenv("COMMA_RUNTIME_AUTH_BROWSER_HARNESS_READY")
	expectedMarker := os.Getenv("COMMA_RUNTIME_AUTH_BROWSER_HARNESS_MARKER")
	if readyPath == "" || expectedMarker == "" {
		t.Skip("started only by the runtime-auth Chromium E2E")
	}
	if os.Geteuid() == 0 {
		t.Fatal("runtime-auth browser target must run as a non-root user")
	}

	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	command := fakeClaudeRuntimeCommand(t)
	t.Setenv("PATH", filepath.Dir(command)+string(os.PathListSeparator)+os.Getenv("PATH"))
	c, err := newConnector(config{name: "browser-auth-target", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeExternalRuntimes)
	if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
		t.Fatal(err)
	}
	c.cfg.runtimeAgent = true
	c.cfg.computeRuntimeWorkloadID = "browser-workload"
	c.cfg.computeRuntimeInstanceID = "browser-runtime"
	c.cfg.computeRuntimeGeneration = 1
	c.cfg.computeRuntimeEpoch = "browser-epoch"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "claude"
	c.cfg.computeRuntimeTenantID = "browser-tenant"
	c.cfg.computeRuntimeProjectID = "browser-project"
	c.setComputeRuntimeExecutionTarget(externalRuntimeExecutionTarget{
		RuntimeInstanceID: "browser-runtime", RuntimeGeneration: 1,
		RuntimeConnectionEpoch: "browser-epoch", WorkloadID: "browser-workload",
		WorkloadGeneration: 1, AllocationID: "browser-allocation", AllocationGeneration: 1,
		ContainerID: "browser-container", ContainerInstanceID: "browser-container-instance",
	}.mapValue())
	attachRuntimeExecutionTestTransport(t, c)
	session := computeRuntimeSession{
		instance: "browser-runtime", generation: 1, epoch: "browser-epoch", kind: "external_worker",
	}
	privateTarget := map[string]any{
		"tenant_id": "browser-tenant", "project_id": "browser-project",
		"workload_id": "browser-workload", "runtime_instance_id": "browser-runtime",
		"generation": 1, "connection_epoch": "browser-epoch", "provider": "claude",
		"actor_id": "browser-admin", "allocation_id": "browser-allocation", "allocation_generation": "1",
	}

	done := make(chan struct{})
	var stop sync.Once
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("content-type", "text/html; charset=utf-8")
		io.WriteString(w, runtimeAuthBrowserHarnessHTML)
	})
	mux.HandleFunc("POST /runtime-auth", func(w http.ResponseWriter, request *http.Request) {
		var input runtimeAuthBrowserHarnessRequest
		decoder := json.NewDecoder(http.MaxBytesReader(w, request.Body, runtimeAuthEnvelopeLimit+4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&input) != nil || input.Target.Kind != "compute_workload" ||
			input.Target.WorkloadID != "browser-workload" {
			runtimeAuthBrowserHarnessError(w)
			return
		}
		method := map[string]string{
			"status": "runtime_auth_status", "input_begin": "runtime_auth_input_begin",
			"input_submit": "runtime_auth_input_submit", "input_cancel": "runtime_auth_input_cancel",
			"verify": "runtime_auth_verify",
		}[input.Action]
		if method == "" {
			runtimeAuthBrowserHarnessError(w)
			return
		}
		params := map[string]any{"target": privateTarget}
		if input.Backend != "" {
			params["backend"] = input.Backend
		}
		if input.Form != "" {
			params["form"] = input.Form
		}
		if input.AttemptID != "" {
			params["attempt_id"] = input.AttemptID
		}
		if input.Envelope != "" {
			params["envelope"] = input.Envelope
		}
		reply := c.computeRuntimeAuthReply(
			request.Context(),
			message{ID: "browser", Method: method, Params: params},
			session,
		)
		if reply.Type != "response" {
			runtimeAuthBrowserHarnessError(w)
			return
		}
		w.Header().Set("content-type", "application/json")
		w.Header().Set("cache-control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "data": map[string]any{"runtime_auth": reply.Result},
		})
	})
	mux.HandleFunc("POST /shutdown", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
		stop.Do(func() { close(done) })
	})

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 2 * time.Second, ErrorLog: log.New(io.Discard, "", 0)}
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(listener) }()
	url := "http://" + listener.Addr().String()
	if err := os.WriteFile(readyPath, []byte(url), 0o600); err != nil {
		t.Fatal(err)
	}

	select {
	case <-done:
	case <-time.After(90 * time.Second):
		t.Fatal("browser harness timed out")
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdown); err != nil {
		t.Fatal(err)
	}
	if err := <-serveDone; !errors.Is(err, http.ErrServerClosed) {
		t.Fatal(err)
	}
	settingsPath, err := runtimeAuthClaudeLocation()
	if err != nil {
		t.Fatal(err)
	}
	saved, err := os.ReadFile(settingsPath)
	if err != nil || !json.Valid(saved) || !bytes.Contains(saved, []byte(expectedMarker)) {
		t.Fatal("browser input did not reach the native provider state")
	}
}

type runtimeAuthBrowserHarnessRequest struct {
	Action string `json:"action"`
	Target struct {
		Kind       string `json:"kind"`
		WorkloadID string `json:"workload_id"`
	} `json:"target"`
	Backend   string `json:"backend,omitempty"`
	Form      string `json:"form,omitempty"`
	AttemptID string `json:"attempt_id,omitempty"`
	Envelope  string `json:"envelope,omitempty"`
}

func runtimeAuthBrowserHarnessError(w http.ResponseWriter) {
	w.Header().Set("content-type", "application/json")
	w.Header().Set("cache-control", "no-store")
	w.WriteHeader(http.StatusConflict)
	io.WriteString(w, `{"ok":false,"error":{"code":"runtime_auth_target_changed"}}`)
}

const runtimeAuthBrowserHarnessHTML = `<!doctype html>
<meta charset="utf-8"><meta name="csrf-token" content="browser-harness">
<div id="panel" data-target='{"kind":"compute_workload","workload_id":"browser-workload"}' data-endpoint="/runtime-auth">
  <p data-auth-status></p>
  <select data-auth-method disabled></select>
  <label>API key<input data-auth-secret type="password" disabled></label>
  <label>Auth file<input data-auth-file type="file" disabled></label>
  <label><input data-auth-save-verify type="checkbox" disabled>Save and verify</label>
  <button data-auth-action="login" disabled>Native login</button>
  <button data-auth-action="save" disabled>Save to runtime</button>
  <button data-auth-action="verify" disabled>Verify</button>
  <button data-auth-action="refresh">Refresh</button>
  <button data-auth-action="cancel" disabled>Cancel</button>
  <p data-auth-feedback role="status"></p>
</div>`
