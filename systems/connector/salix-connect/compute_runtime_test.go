package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func testComputeRuntimeConfig(url string) config {
	return config{
		computeRuntimeURL:            url,
		computeRuntimeBootstrapToken: "bootstrap",
		computeRuntimeWorkloadID:     "workload",
		computeRuntimeInstanceID:     "runtime:workload",
		computeRuntimeEpoch:          "7",
		computeRuntimeGeneration:     1,
		computeRuntimeKind:           "external_worker",
		computeRuntimeProvider:       "codex",
		computeRuntimeTenantID:       "tenant",
		computeRuntimeProjectID:      "project",
	}
}

func testComputeRuntimeExecutionTarget() map[string]any {
	return externalRuntimeExecutionTarget{
		RuntimeInstanceID: "runtime:workload", RuntimeGeneration: 1,
		RuntimeConnectionEpoch: "7", WorkloadID: "workload", WorkloadGeneration: 1,
		AllocationID: "allocation", AllocationGeneration: 1,
		ContainerID: "container", ContainerInstanceID: "container-instance",
	}.mapValue()
}

func jsonStringListContains(value any, want string) bool {
	items, ok := value.([]any)
	if !ok {
		return false
	}
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}

func TestComputeRuntimeConfiguredRequiresHandshakeIdentity(t *testing.T) {
	base := testComputeRuntimeConfig("https://salix.test")

	if !computeRuntimeConfigured(base) {
		t.Fatal("complete compute runtime configuration should be enabled")
	}

	for name, mutate := range map[string]func(*config){
		"url":        func(cfg *config) { cfg.computeRuntimeURL = " " },
		"token":      func(cfg *config) { cfg.computeRuntimeBootstrapToken = "" },
		"workload":   func(cfg *config) { cfg.computeRuntimeWorkloadID = "" },
		"instance":   func(cfg *config) { cfg.computeRuntimeInstanceID = "" },
		"epoch":      func(cfg *config) { cfg.computeRuntimeEpoch = "" },
		"generation": func(cfg *config) { cfg.computeRuntimeGeneration = 0 },
		"kind":       func(cfg *config) { cfg.computeRuntimeKind = "" },
		"provider":   func(cfg *config) { cfg.computeRuntimeProvider = "" },
		"tenant":     func(cfg *config) { cfg.computeRuntimeTenantID = "" },
		"project":    func(cfg *config) { cfg.computeRuntimeProjectID = "" },
	} {
		t.Run(name, func(t *testing.T) {
			cfg := base
			mutate(&cfg)
			if computeRuntimeConfigured(cfg) {
				t.Fatalf("incomplete compute runtime configuration was accepted: %#v", cfg)
			}
		})
	}
}

func TestComputeRuntimeIdentitySurvivesBootstrapErasure(t *testing.T) {
	cfg := testComputeRuntimeConfig("https://salix.test")
	cfg.computeRuntimeBootstrapToken = ""

	if computeRuntimeConfigured(cfg) {
		t.Fatal("carrier startup accepted an erased bootstrap credential")
	}
	if !computeRuntimeIdentityConfigured(cfg) {
		t.Fatal("post-handshake workload identity was erased with the bootstrap credential")
	}
}

func TestComputeRuntimeSocketURLAndReadyIdentity(t *testing.T) {
	got, err := computeRuntimeSocketURL("https://salix.test/")
	if err != nil {
		t.Fatalf("socket URL: %v", err)
	}
	if got != "wss://salix.test/v1/compute/runtime/socket" {
		t.Fatalf("socket URL = %q", got)
	}

	cfg := testComputeRuntimeConfig("https://salix.test")
	ready := computeRuntimeReadyFrame{
		RuntimeInstanceID: "runtime:workload",
		WorkloadID:        "workload",
		Generation:        1,
		RuntimeKind:       "external_worker",
		ConnectionEpoch:   "7",
		Features:          []string{"runtime.input.v1", "runtime.event.v1", "runtime.auth.v1", "runtime.execution.v1"},
		Token:             "runtime-token",
		ExecutionTarget:   testComputeRuntimeExecutionTarget(),
	}
	session, err := newComputeRuntimeSession(ready, cfg)
	if err != nil {
		t.Fatalf("ready frame: %v", err)
	}
	if session.token != "runtime-token" || session.kind != "external_worker" {
		t.Fatalf("session = %#v", session)
	}

	ready.Generation = 2
	if _, err := newComputeRuntimeSession(ready, cfg); err == nil {
		t.Fatal("generation mismatch was accepted")
	}
	ready.Generation = 1
	ready.Features = []string{"runtime.input.v1", "runtime.event.v1"}
	ready.ExecutionTarget = nil
	session, err = newComputeRuntimeSession(ready, cfg)
	if err != nil {
		t.Fatalf("base carrier features were rejected: %v", err)
	}
	if session.supports("runtime.auth.v1") || session.supports("runtime.execution.v1") {
		t.Fatalf("missing optional features were fabricated: %#v", session.features)
	}
	ready.Features = nil
	if _, err := newComputeRuntimeSession(ready, cfg); err == nil {
		t.Fatal("featureless ready frame was accepted")
	}
}

func TestComputeRuntimeInputLoopRetriesLostHandshakeAndClearsBootstrap(t *testing.T) {
	previousRetryInterval := computeRuntimeRetryInterval
	computeRuntimeRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { computeRuntimeRetryInterval = previousRetryInterval })

	var connectionCount atomic.Int32
	serverErrors := make(chan error, 4)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverErrors <- err
			return
		}
		defer conn.Close()

		if r.Header.Get("authorization") == "" {
			serverErrors <- errMissingRuntimeAuthorization{}
			return
		}
		_, data, err := conn.ReadMessage()
		if err != nil {
			serverErrors <- err
			return
		}
		var hello map[string]any
		if err := json.Unmarshal(data, &hello); err != nil {
			serverErrors <- err
			return
		}
		if hello["type"] != "runtime.hello" ||
			hello["protocol_version"] != float64(1) ||
			!jsonStringListContains(hello["supported_features"], "runtime.input.v1") ||
			!jsonStringListContains(hello["supported_features"], "runtime.event.v1") ||
			!jsonStringListContains(hello["supported_features"], "runtime.auth.v1") ||
			hello["input_cursor"] != "" || hello["event_cursor"] != "" {
			serverErrors <- errInvalidRuntimeHello{}
			return
		}

		if connectionCount.Add(1) == 1 {
			// The server has accepted the handshake request but loses its
			// response. The client must retry with the same bootstrap epoch.
			return
		}

		if r.Header.Get("authorization") != "Bearer bootstrap" {
			serverErrors <- errUnexpectedRuntimeAuthorization{}
			return
		}
		if err := conn.WriteJSON(map[string]any{
			"type":                "runtime.ready",
			"runtime_instance_id": "runtime:workload",
			"workload_id":         "workload",
			"generation":          1,
			"runtime_kind":        "external_worker",
			"connection_epoch":    "7",
			"features":            []string{"runtime.input.v1", "runtime.event.v1", "runtime.auth.v1", "runtime.execution.v1"},
			"input_cursor":        "",
			"event_cursor":        "",
			"token":               "runtime-token",
			"execution_target":    testComputeRuntimeExecutionTarget(),
		}); err != nil {
			serverErrors <- err
			return
		}
		if err := acknowledgeRuntimeOperationList(conn, nil); err != nil {
			serverErrors <- err
		}
	}))
	defer server.Close()

	t.Setenv("SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN", "bootstrap")
	c := &connector{cfg: testComputeRuntimeConfig(server.URL)}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		c.computeRuntimeInputLoop(ctx)
		close(done)
	}()

	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for connectionCount.Load() < 2 {
		select {
		case <-deadline.C:
			t.Fatal("compute runtime input loop did not retry the lost handshake")
		case err := <-serverErrors:
			t.Fatalf("runtime test server: %v", err)
		case <-time.After(10 * time.Millisecond):
		}
	}

	for {
		if _, ok := os.LookupEnv("SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN"); !ok {
			break
		}
		select {
		case <-deadline.C:
			t.Fatal("bootstrap token remained after the WSS handshake succeeded")
		case err := <-serverErrors:
			t.Fatalf("runtime test server: %v", err)
		case <-time.After(10 * time.Millisecond):
		}
	}

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime input loop did not stop")
	}
	if c.cfg.computeRuntimeBootstrapToken != "" {
		t.Fatal("bootstrap token remained in connector config after the WSS handshake succeeded")
	}
}

func TestComputeRuntimeInputLoopRetriesControlRecoveryWithEpochCredential(t *testing.T) {
	for _, reason := range []string{"runtime_control_unavailable", "runtime_recovery_expired"} {
		t.Run(reason, func(t *testing.T) { testComputeRuntimeRecovery(t, reason) })
	}
}

func testComputeRuntimeRecovery(t *testing.T, reason string) {
	previousRetryInterval := computeRuntimeRetryInterval
	computeRuntimeRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { computeRuntimeRetryInterval = previousRetryInterval })

	authorizations := make(chan string, 3)
	serverErrors := make(chan error, 3)
	var connectionCount atomic.Int32
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverErrors <- err
			return
		}
		defer conn.Close()

		attempt := connectionCount.Add(1)
		authorizations <- r.Header.Get("authorization")
		if _, _, err := conn.ReadMessage(); err != nil {
			serverErrors <- err
			return
		}

		if attempt == 2 {
			if err := conn.WriteJSON(map[string]any{"type": "runtime.error", "error": reason}); err != nil {
				serverErrors <- err
			}
			return
		}
		if err := conn.WriteJSON(map[string]any{
			"type":                "runtime.ready",
			"runtime_instance_id": "runtime:workload",
			"workload_id":         "workload",
			"generation":          1,
			"runtime_kind":        "external_worker",
			"connection_epoch":    "7",
			"features":            []string{"runtime.input.v1", "runtime.event.v1", "runtime.auth.v1", "runtime.execution.v1"},
			"input_cursor":        "",
			"event_cursor":        "",
			"token":               "runtime-token",
			"execution_target":    testComputeRuntimeExecutionTarget(),
		}); err != nil {
			serverErrors <- err
			return
		}
		if err := acknowledgeRuntimeOperationList(conn, nil); err != nil {
			serverErrors <- err
			return
		}

		// Cover a rejection on an established socket as well as the next
		// handshake. Neither may erase the epoch credential or end the loop.
		if attempt == 1 {
			if err := conn.WriteJSON(map[string]any{"type": "runtime.error", "error": reason}); err != nil {
				serverErrors <- err
			}
		}

	}))
	defer server.Close()

	t.Setenv("SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN", "bootstrap")
	c := &connector{cfg: testComputeRuntimeConfig(server.URL)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		c.computeRuntimeInputLoop(ctx)
		close(done)
	}()

	select {
	case got := <-authorizations:
		if got != "Bearer bootstrap" {
			t.Fatalf("first authorization = %q", got)
		}
	case err := <-serverErrors:
		t.Fatalf("runtime test server: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("compute runtime input loop did not connect")
	}

	select {
	case got := <-authorizations:
		if got != "Bearer runtime-token" {
			t.Fatalf("reconnect authorization = %q", got)
		}
	case err := <-serverErrors:
		t.Fatalf("runtime test server: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("compute runtime input loop did not reconnect")
	}

	select {
	case got := <-authorizations:
		if got != "Bearer runtime-token" {
			t.Fatalf("control recovery authorization = %q", got)
		}
	case <-done:
		t.Fatal("temporary Host recovery permanently stopped the Runtime carrier")
	case err := <-serverErrors:
		t.Fatalf("runtime test server: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("Runtime did not retry after Host control recovered")
	}

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime input loop did not stop")
	}
}

func TestComputeRuntimeSocketSendsKeepalivePing(t *testing.T) {
	pingSeen := make(chan struct{}, 1)
	serverErrors := make(chan error, 1)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverErrors <- err
			return
		}
		defer conn.Close()
		conn.SetPingHandler(func(string) error {
			select {
			case pingSeen <- struct{}{}:
			default:
			}
			return nil
		})
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}

	c := &connector{runtimePingInterval: 10 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		emptyToken, emptyInputCursor, emptyEventCursor := "", "", ""
		done <- c.consumeComputeRuntimeSocket(
			ctx,
			&computeRuntimeWire{conn: ws},
			&computeRuntimeSession{},
			&emptyToken,
			&emptyInputCursor,
			&emptyEventCursor,
		)
	}()

	select {
	case <-pingSeen:
	case err := <-serverErrors:
		t.Fatalf("runtime test server: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime did not send a keepalive ping")
	}

	cancel()
	_ = ws.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime socket consumer did not stop")
	}
}

func TestComputeRuntimeCommandUsesExactPrivateInventoryTarget(t *testing.T) {
	inventory := newRuntimeInventory()
	inventory.runtimes["codex\x00/usr/local/bin/codex"] = map[string]any{
		"kind": "external", "provider": "codex", "identity_material": "/usr/local/bin/codex",
	}
	c := &connector{runtimeInventory: inventory}

	command, err := c.computeRuntimeCommand("codex")
	if err != nil {
		t.Fatal(err)
	}
	if command != "/usr/local/bin/codex" {
		t.Fatalf("command = %q", command)
	}
}

func TestComputeRuntimeCommandRejectsAmbiguousPrivateInventory(t *testing.T) {
	inventory := newRuntimeInventory()
	inventory.runtimes["codex\x00/a"] = map[string]any{
		"kind": "external", "provider": "codex", "identity_material": "/a",
	}
	inventory.runtimes["codex\x00/b"] = map[string]any{
		"kind": "external", "provider": "codex", "identity_material": "/b",
	}
	c := &connector{runtimeInventory: inventory}

	if _, err := c.computeRuntimeCommand("codex"); err == nil {
		t.Fatal("ambiguous provider target was accepted")
	}
}

func TestComputeRuntimeAcceptsClaudeAtLocalBoundaries(t *testing.T) {
	t.Run("configuration", func(t *testing.T) {
		cfg := testComputeRuntimeConfig("https://salix.test")
		cfg.computeRuntimeProvider = "claude"
		if !computeRuntimeConfigured(cfg) {
			t.Fatal("complete Claude compute runtime configuration was rejected")
		}
	})

	t.Run("command resolution", func(t *testing.T) {
		inventory := newRuntimeInventory()
		inventory.runtimes["claude\x00/usr/local/bin/claude"] = map[string]any{
			"kind": "external", "provider": "claude", "identity_material": "/usr/local/bin/claude",
		}
		c := &connector{runtimeInventory: inventory}
		command, err := c.computeRuntimeCommand("claude")
		if err != nil {
			t.Fatal(err)
		}
		if command != "/usr/local/bin/claude" {
			t.Fatalf("command = %q", command)
		}
	})

	t.Run("input admission", func(t *testing.T) {
		t.Setenv("HOME", t.TempDir())
		t.Setenv("ANTHROPIC_API_KEY", "host-api-key")
		t.Setenv("ANTHROPIC_AUTH_TOKEN", "host-auth-token")
		t.Setenv("ANTHROPIC_BASE_URL", "https://host.example")
		logPath := filepath.Join(t.TempDir(), "claude-compute.log")
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", logPath)
		command := fakeClaudeRuntimeCommand(t)
		c, err := newConnector(config{
			name: "claude-compute-test", root: t.TempDir(), systemInfoInterval: 0,
			runtimeAgent: true, computeRuntimeKind: "external_worker", computeRuntimeProvider: "claude",
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(c.closeExternalRuntimes)
		c.setComputeRuntimeExecutionTarget(testComputeRuntimeExecutionTarget())
		attachRuntimeExecutionTestTransport(t, c)
		c.runtimeInventory.mu.Lock()
		c.runtimeInventory.runtimes = map[string]map[string]any{
			"claude\x00" + command: {
				"kind": "external", "provider": "claude", "identity_material": command,
			},
		}
		c.runtimeInventory.mu.Unlock()

		err = c.consumeComputeRuntimeInput(context.Background(), computeRuntimeInputRecord{Payload: map[string]any{
			"kind":                     "external",
			"provider":                 "claude",
			"session_id":               "session-1",
			"dispatch_id":              "dispatch-1",
			"runtime_capability_token": "token-1",
			"input_messages":           []any{map[string]any{"role": "user", "content": "compute prompt"}},
		}})
		if err != nil {
			t.Fatal(err)
		}

		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			raw, _ := os.ReadFile(logPath)
			if strings.Contains(string(raw), "compute prompt") {
				if !strings.Contains(string(raw), "provider_env=//") || strings.Contains(string(raw), "host-api-key") {
					t.Fatalf("managed Claude process inherited host provider credentials:\n%s", raw)
				}
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		raw, _ := os.ReadFile(logPath)
		t.Fatalf("Claude Compute input did not reach the CLI:\n%s", raw)
	})
}

func TestComputeRuntimeStillRejectsUnsupportedExternalProviders(t *testing.T) {
	for _, provider := range []string{"kimi", "unknown"} {
		t.Run(provider, func(t *testing.T) {
			cfg := testComputeRuntimeConfig("https://salix.test")
			cfg.computeRuntimeProvider = provider
			if computeRuntimeConfigured(cfg) {
				t.Fatalf("compute runtime accepted unsupported provider %q", provider)
			}

			inventory := newRuntimeInventory()
			identity := "/usr/local/bin/" + provider
			inventory.runtimes[provider+"\x00"+identity] = map[string]any{
				"kind": "external", "provider": provider, "identity_material": identity,
			}
			c := &connector{runtimeInventory: inventory}
			if _, err := c.computeRuntimeCommand(provider); err == nil {
				t.Fatalf("compute runtime resolved unsupported provider %q", provider)
			}
		})
	}
}

func TestPrepareComputeRuntimePopulatesPrivateProviderInventory(t *testing.T) {
	inventory := newRuntimeInventory()
	inventory.run = func(target runtimeProbeTarget) map[string]any {
		return map[string]any{
			"kind": "external", "provider": target.provider,
			"identity_material": target.identityMaterial,
		}
	}
	c := &connector{
		cfg:              testComputeRuntimeConfig("https://salix.test"),
		runtimeInventory: inventory,
	}
	c.cfg.computeRuntimeProvider = "pi"

	command := filepath.Join(t.TempDir(), "pi")
	if err := os.WriteFile(command, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", filepath.Dir(command))

	if err := c.prepareComputeRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	got, err := c.computeRuntimeCommand("pi")
	if err != nil {
		t.Fatal(err)
	}
	if got != command {
		t.Fatalf("command = %q, want %q", got, command)
	}
}

func TestPrepareMeetingRuntimeDoesNotProbeAgentProviders(t *testing.T) {
	c := &connector{cfg: config{computeRuntimeKind: "meeting_runtime"}}
	if err := c.prepareComputeRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestComputeRuntimeShimUsesWritableWorkspaceAfterBootstrap(t *testing.T) {
	root := t.TempDir()
	c := &connector{
		root: root,
		cfg: config{
			runtimeAgent:             true,
			computeRuntimeURL:        "https://runtime.example",
			computeRuntimeWorkloadID: "workload",
			computeRuntimeInstanceID: "runtime:workload",
			computeRuntimeEpoch:      "1",
			computeRuntimeGeneration: 1,
			computeRuntimeKind:       "external_worker",
			computeRuntimeProvider:   "codex",
			computeRuntimeTenantID:   "tenant",
			computeRuntimeProjectID:  "project",
		},
		salixCLIDirs: map[string]string{},
	}
	if computeRuntimeConfigured(c.cfg) {
		t.Fatal("post-bootstrap runtime unexpectedly retained a complete bootstrap configuration")
	}

	dir, err := c.ensureSalixCLI("pi")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(dir) != root {
		t.Fatalf("shim dir %q is outside workspace %q", dir, root)
	}
}

func TestComputeRuntimeReconnectRecoversLostAckConfirmation(t *testing.T) {
	previousRetryInterval := computeRuntimeRetryInterval
	computeRuntimeRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { computeRuntimeRetryInterval = previousRetryInterval })

	var meetingJoins atomic.Int32
	meeting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/meetings/join" {
			http.NotFound(w, r)
			return
		}
		meetingJoins.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{"session": "meeting-session"})
	}))
	defer meeting.Close()

	const inputID = "input-ack-response-loss"
	var connectionCount atomic.Int32
	serverErrors := make(chan error, 8)
	thirdHello := make(chan map[string]any, 1)
	hold := make(chan struct{})
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverErrors <- err
			return
		}
		defer conn.Close()

		_, rawHello, err := conn.ReadMessage()
		if err != nil {
			serverErrors <- err
			return
		}
		var hello map[string]any
		if err := json.Unmarshal(rawHello, &hello); err != nil {
			serverErrors <- err
			return
		}

		connection := connectionCount.Add(1)
		readyCursor := ""
		if connection >= 2 {
			readyCursor = inputID
		}
		if err := conn.WriteJSON(map[string]any{
			"type":                "runtime.ready",
			"runtime_instance_id": "runtime:workload",
			"workload_id":         "workload",
			"generation":          1,
			"runtime_kind":        "meeting_runtime",
			"connection_epoch":    "7",
			"features":            []string{"runtime.input.v1", "runtime.event.v1"},
			"input_cursor":        "",
			"event_cursor":        readyCursor,
			"token":               "runtime-token",
		}); err != nil {
			serverErrors <- err
			return
		}

		switch connection {
		case 1:
			if hello["event_cursor"] != "" {
				serverErrors <- errors.New("first connection advanced the event cursor")
				return
			}
			if err := conn.WriteJSON(map[string]any{
				"type":             "runtime.input",
				"input_id":         inputID,
				"generation":       1,
				"connection_epoch": "7",
				"payload": map[string]any{
					"frame_type": "meeting.join",
					"payload": map[string]any{
						"meeting_id":    "meeting-1",
						"meet_url":      "https://meeting.test",
						"runtime_token": "meeting-token",
					},
				},
			}); err != nil {
				serverErrors <- err
				return
			}
			var ack map[string]any
			if err := conn.ReadJSON(&ack); err != nil {
				serverErrors <- err
				return
			}
			if ack["type"] != "runtime.input_ack" || ack["input_id"] != inputID {
				serverErrors <- errors.New("invalid runtime input ACK")
			}
			// The durable ACK commits, but its confirmation is lost with the socket.
		case 2:
			if hello["event_cursor"] != "" {
				serverErrors <- errors.New("client advanced its cursor before ACK confirmation")
			}
		case 3:
			thirdHello <- hello
			<-hold
		}
	}))
	defer server.Close()

	cfg := testComputeRuntimeConfig(server.URL)
	cfg.computeRuntimeKind = "meeting_runtime"
	cfg.meetURL = meeting.URL
	c := &connector{cfg: cfg}
	t.Cleanup(func() {
		if c.meetServer != nil {
			_ = c.meetServer.Close()
		}
	})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		c.computeRuntimeInputLoop(ctx)
		close(done)
	}()

	select {
	case hello := <-thirdHello:
		if hello["event_cursor"] != inputID {
			t.Fatalf("reconciled event cursor = %#v", hello["event_cursor"])
		}
	case err := <-serverErrors:
		t.Fatalf("runtime test server: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("compute runtime did not reconnect through ACK response loss")
	}
	if meetingJoins.Load() != 1 {
		t.Fatalf("meeting join count = %d", meetingJoins.Load())
	}

	cancel()
	close(hold)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime input loop did not stop")
	}
}

func TestComputeRuntimeSocketCompletesPendingEventRequest(t *testing.T) {
	release := make(chan struct{})
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		defer conn.Close()
		if err := conn.WriteJSON(message{
			ID:   "event-1",
			Type: "response",
			Result: map[string]any{
				"accepted_event_ids": []any{"event-1"},
			},
		}); err != nil {
			t.Errorf("write response: %v", err)
			return
		}
		<-release
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer ws.Close()

	c := &connector{runtimePending: map[string]runtimePendingRequest{}}
	transport := &runtimeTransport{done: make(chan struct{})}
	reply := make(chan message, 1)
	c.runtimePending["event-1"] = runtimePendingRequest{transport: transport, reply: reply}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		session := &computeRuntimeSession{}
		emptyToken, emptyInputCursor, emptyEventCursor := "", "", ""
		done <- c.consumeComputeRuntimeSocket(
			ctx,
			&computeRuntimeWire{conn: ws},
			session,
			&emptyToken,
			&emptyInputCursor,
			&emptyEventCursor,
		)
	}()

	select {
	case response := <-reply:
		if response.Type != "response" || response.ID != "event-1" {
			t.Fatalf("response = %#v", response)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime response did not settle the pending event request")
	}

	close(release)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime socket consumer did not stop")
	}
}

type errMissingRuntimeAuthorization struct{}

func (errMissingRuntimeAuthorization) Error() string { return "missing runtime authorization" }

type errInvalidRuntimeHello struct{}

func (errInvalidRuntimeHello) Error() string { return "invalid runtime hello" }

type errUnexpectedRuntimeAuthorization struct{}

func (errUnexpectedRuntimeAuthorization) Error() string { return "unexpected runtime authorization" }

func TestComputeRuntimeAuthDoesNotBlockSocketControl(t *testing.T) {
	gate := filepath.Join(t.TempDir(), "account-read")
	if err := os.WriteFile(gate, []byte("open"), 0600); err != nil {
		t.Fatal(err)
	}
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":      "none",
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE": gate,
	})
	c.cfg.computeRuntimeWorkloadID = "workload"
	c.cfg.computeRuntimeInstanceID = "runtime"
	c.cfg.computeRuntimeGeneration = 1
	c.cfg.computeRuntimeEpoch = "epoch"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	c.setComputeRuntimeExecutionTarget(map[string]any{
		"runtime_instance_id": "runtime", "runtime_generation": 1,
		"runtime_connection_epoch": "epoch", "workload_id": "workload", "workload_generation": 1,
		"allocation_id": "allocation", "allocation_generation": 1,
		"container_id": "container", "container_instance_id": "instance",
	})
	if err := os.Remove(gate); err != nil {
		t.Fatal(err)
	}
	defer os.WriteFile(gate, []byte("open"), 0600)
	peerReady := make(chan *websocket.Conn, 1)
	release := make(chan struct{})
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		peerReady <- conn
		<-release
	}))
	defer server.Close()
	defer close(release)
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	peer := <-peerReady
	reply := make(chan message, 1)
	c.runtimePending["event-ack"] = runtimePendingRequest{transport: &runtimeTransport{done: make(chan struct{})}, reply: reply}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	wire := &computeRuntimeWire{conn: ws}
	deactivate := c.activateRuntimeTransport(wire.send)
	defer deactivate()
	go func() {
		session := computeRuntimeSession{instance: "runtime", epoch: "epoch", generation: 1, kind: "external_worker", features: computeRuntimeFeatures(c.cfg)}
		token, input, event := "", "", ""
		done <- c.consumeComputeRuntimeSocket(ctx, wire, &session, &token, &input, &event)
	}()
	var delayedList message
	if err := peer.ReadJSON(&delayedList); err != nil {
		t.Fatal(err)
	}
	if delayedList.Method != "runtime_execution" || stringParam(delayedList.Params, "action") != "list" {
		t.Fatalf("unexpected reconciliation request: %#v", delayedList)
	}
	statusParams := map[string]any{
		"target": map[string]any{"tenant_id": "tenant", "project_id": "project", "workload_id": "workload", "runtime_instance_id": "runtime", "generation": 1, "connection_epoch": "epoch", "provider": "codex", "actor_id": "admin"},
	}
	if err := peer.WriteJSON(message{ID: "status-during-recovery", Type: "request", Method: "runtime_auth_status", Params: statusParams}); err != nil {
		t.Fatal(err)
	}
	var recoveryStatus message
	if err := peer.ReadJSON(&recoveryStatus); err != nil {
		t.Fatalf("status was blocked by delayed reconciliation: %v", err)
	}
	if recoveryStatus.ID != "status-during-recovery" || recoveryStatus.Error == "runtime operation recovery pending" {
		t.Fatalf("independent status was rejected by global recovery: %#v", recoveryStatus)
	}
	target := mapParam(delayedList.Params, "target")
	if err := peer.WriteJSON(message{ID: delayedList.ID, Type: "response", Result: map[string]any{
		"allocation_authority": stringParam(target, "allocation_id"), "container_instance_id": stringParam(target, "container_instance_id"),
		"status": "EXECUTION_LIST_STATUS_EMPTY", "executions": []any{},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := awaitRuntimeOperationReconciliation(peer); err != nil {
		t.Fatal(err)
	}
	for range cap(c.runtimeAuthSlots) {
		c.runtimeAuthSlots <- struct{}{}
	}
	if err := peer.WriteJSON(message{ID: "auth-overflow", Type: "request", Method: "runtime_auth_login_start", Params: map[string]any{
		"target": map[string]any{"tenant_id": "tenant", "project_id": "project", "workload_id": "workload", "runtime_instance_id": "runtime", "generation": 1, "connection_epoch": "epoch", "provider": "codex"},
		"flow":   "device_code",
	}}); err != nil {
		t.Fatal(err)
	}
	_ = peer.SetReadDeadline(time.Now().Add(2 * time.Second))
	var overflow message
	if err := peer.ReadJSON(&overflow); err != nil {
		t.Fatalf("saturated auth blocked socket control: %v", err)
	}
	if overflow.ID != "auth-overflow" || overflow.Type != "error" || overflow.Error != "runtime operation capacity exhausted" {
		t.Fatalf("unexpected saturation result: %+v", overflow)
	}
	if err := peer.WriteJSON(message{ID: "auth-status", Type: "request", Method: "runtime_auth_status", Params: statusParams}); err != nil {
		t.Fatal(err)
	}
	var statusReply message
	if err := peer.ReadJSON(&statusReply); err != nil {
		t.Fatalf("status was not reachable while operation slots were full: %v", err)
	}
	if statusReply.ID != "auth-status" || statusReply.Error == "runtime control capacity exhausted" {
		t.Fatalf("unexpected control result: %+v", statusReply)
	}
	if err := peer.WriteJSON(message{ID: "event-ack", Type: "response", Result: map[string]any{"accepted": true}}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-reply:
	case <-time.After(2 * time.Second):
		t.Fatal("native auth blocked the event acknowledgement")
	}
	_ = peer.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("native auth blocked disconnect observation")
	}
	if err := os.WriteFile(gate, []byte("open"), 0600); err != nil {
		t.Fatal(err)
	}
	for range cap(c.runtimeAuthSlots) {
		<-c.runtimeAuthSlots
	}
}

func TestRuntimeAuthDiagnosticsDoNotRequireExecutionFeature(t *testing.T) {
	session := computeRuntimeSession{features: []string{"runtime.auth.v1"}}
	for _, method := range []string{"runtime_auth_read", "runtime_auth_status"} {
		if missing := missingComputeRuntimeFeature(method, session); missing != "" {
			t.Fatalf("%s requires unrelated feature %q", method, missing)
		}
	}
	for _, method := range []string{"runtime_auth_login_start", "runtime_auth_verify", "runtime_auth_input_begin"} {
		if missing := missingComputeRuntimeFeature(method, session); missing != "runtime.execution.v1" {
			t.Fatalf("%s missing feature = %q", method, missing)
		}
	}
}

func TestMigrationOperationsUseIndependentHostRights(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan message, 8)
	attachRuntimeExecutionRecordingTransport(t, c, requests)

	rightA, err := c.acquireRuntimeOperation(context.Background(), "request-a", runtimeMigrationOperationFamily("move-a"), "migration_export:move-a", "migration_export", 30*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	rightB, err := c.acquireRuntimeOperation(context.Background(), "request-b", runtimeMigrationOperationFamily("move-b"), "migration_export:move-b", "migration_export", 30*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if rightA.ActivityID == rightB.ActivityID || stringParam(rightA.Target, "container_instance_id") != stringParam(rightB.Target, "container_instance_id") {
		t.Fatalf("rights are not independent exact-target activities: A=%+v B=%+v", rightA, rightB)
	}
	first, second := <-requests, <-requests
	if stringParam(first.Params, "action") != "acquire" || stringParam(second.Params, "action") != "acquire" ||
		stringParam(first.Params, "execution_id") == stringParam(second.Params, "execution_id") {
		t.Fatalf("migration acquire requests=%#v %#v", first, second)
	}
	if err := c.releaseRuntimeOperation(context.Background(), "request-a", "migration_export:move-a"); err != nil {
		t.Fatal(err)
	}
	if err := c.releaseRuntimeOperation(context.Background(), "request-b", "migration_export:move-b"); err != nil {
		t.Fatal(err)
	}
}

func acknowledgeRuntimeOperationList(conn *websocket.Conn, executions []any) error {
	var request message
	if err := conn.ReadJSON(&request); err != nil {
		return err
	}
	if request.Method != "runtime_execution" || stringParam(request.Params, "action") != "list" {
		return fmt.Errorf("unexpected runtime operation reconciliation request: %#v", request)
	}
	target := mapParam(request.Params, "target")
	status := "EXECUTION_LIST_STATUS_EMPTY"
	if len(executions) > 0 {
		status = "EXECUTION_LIST_STATUS_PRESENT"
	}
	return conn.WriteJSON(message{ID: request.ID, Type: "response", Result: map[string]any{
		"allocation_authority":  stringParam(target, "allocation_id"),
		"container_instance_id": stringParam(target, "container_instance_id"),
		"status":                status,
		"executions":            executions,
	}})
}

func awaitRuntimeOperationReconciliation(conn *websocket.Conn) error {
	for attempt := 0; attempt < 20; attempt++ {
		id := fmt.Sprintf("reconciliation-probe-%d", attempt)
		if err := conn.WriteJSON(message{ID: id, Type: "request", Method: "reconciliation_probe"}); err != nil {
			return err
		}
		var response message
		if err := conn.ReadJSON(&response); err != nil {
			return err
		}
		if response.ID != id {
			return fmt.Errorf("unexpected reconciliation probe response: %#v", response)
		}
		if response.Error != "runtime operation recovery pending" {
			return nil
		}
		time.Sleep(time.Millisecond)
	}
	return errors.New("runtime operation reconciliation did not complete")
}

func TestRuntimeOperationAcquireMatchesExistingRightWithoutReplay(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.setComputeRuntimeExecutionTarget(map[string]any{
		"runtime_instance_id": "runtime", "runtime_generation": 1,
		"container_id": "container", "container_instance_id": "instance",
	})
	transport := &runtimeTransport{done: make(chan struct{})}
	var calls atomic.Int32
	transport.send = func(_ context.Context, request message) error {
		calls.Add(1)
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{
			"execution_id": stringParam(request.Params, "execution_id"), "acquired": false,
		}})
		return nil
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()

	if right, err := c.acquireRuntimeOperation(context.Background(), "request", "auth:key", "auth:key", "auth_operation", time.Minute); err != nil || right.Phase != runtimeOperationActive {
		t.Fatalf("matching Host right was not resumed idempotently: %+v, %v", right, err)
	}
	if right, present := c.runtimeOperations.familyState("auth:key"); !present || right.Phase != runtimeOperationActive {
		t.Fatalf("matching Host right was not retained as active: %+v", right)
	}
	if _, err := c.acquireRuntimeOperation(context.Background(), "request", "auth:key", "auth:key", "auth_operation", time.Minute); err == nil || !strings.Contains(err.Error(), "action required") {
		t.Fatalf("local existing right was accepted for replay: %v", err)
	}
	if calls.Load() != 1 {
		t.Fatalf("local duplicate issued %d Host acquires", calls.Load())
	}
}

func TestRuntimeOperationReconciliationFailsRecoveredAuthAndMigrationClosed(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	target := testComputeRuntimeExecutionTarget()
	target["runtime_instance_id"] = "runtime-instance-inspection"
	c.setComputeRuntimeExecutionTarget(target)
	authParams := map[string]any{"target": map[string]any{
		"runtime_instance_id": "runtime:workload", "provider": "codex", "actor_id": "admin",
	}}
	authKey := runtimeAuthOperationKey(authParams)
	authActivity := authKey + ":verify:request-before-reconnect"
	migrationKey := "migration_export:move-recovered"
	transport := &runtimeTransport{done: make(chan struct{})}
	transport.send = func(_ context.Context, request message) error {
		if request.Method != "runtime_execution" || stringParam(request.Params, "action") != "list" {
			return fmt.Errorf("unexpected recovery request: %#v", request)
		}
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{
			"allocation_authority":  stringParam(target, "allocation_id"),
			"container_instance_id": stringParam(target, "container_instance_id"),
			"status":                "EXECUTION_LIST_STATUS_PRESENT",
			"executions": []any{
				map[string]any{"execution_id": authActivity, "owner": "runtime-instance-inspection:1", "kind": "EXECUTION_KIND_AUTH_OPERATION"},
				map[string]any{"execution_id": migrationKey, "owner": "runtime-instance-inspection:1", "kind": "EXECUTION_KIND_MIGRATION_EXPORT"},
			},
		}})
		return nil
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()

	c.reconcileRuntimeOperationRights(context.Background())
	if !c.runtimeOperations.familyRecoveryRequired(authKey) ||
		!c.runtimeOperations.familyRecoveryRequired(runtimeMigrationOperationFamily("move-recovered")) {
		t.Fatalf("Host rights were not recovered as unknown: %#v", c.runtimeOperations.snapshot())
	}
	if _, err := c.computePrivateRuntimeAuthOwned(
		context.Background(),
		message{ID: "status", Method: "runtime_auth_status", Params: authParams},
		computeRuntimeSession{},
		nil,
	); err == nil || !strings.Contains(err.Error(), "action required") {
		t.Fatalf("recovered auth status did not fail closed: %v", err)
	}
	for _, method := range []string{"runtime_auth_input_submit", "runtime_auth_input_cancel"} {
		if _, err := c.computePrivateRuntimeAuthOwned(
			context.Background(),
			message{ID: method, Method: method, Params: authParams},
			computeRuntimeSession{},
			nil,
		); err == nil || !strings.Contains(err.Error(), "action required") {
			t.Fatalf("recovered auth %s did not fail closed: %v", method, err)
		}
	}
	if _, err := c.computePrivateRuntimeAuthOwned(
		context.Background(),
		message{ID: "verify-after-reconnect", Method: "runtime_auth_verify", Params: authParams},
		computeRuntimeSession{},
		nil,
	); err == nil || !strings.Contains(err.Error(), "action required") {
		t.Fatalf("recovered verify child did not fence the auth family: %v", err)
	}
	if _, err := c.computeMigrationOperation(context.Background(), "migration-status", "status", map[string]any{"operation_id": "move-recovered"}); err == nil || !strings.Contains(err.Error(), "action required") {
		t.Fatalf("recovered migration status did not fail closed: %v", err)
	}
}

func TestRuntimeOperationReconciliationAcceptsStoppedWithoutCurrentInstance(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	target := testComputeRuntimeExecutionTarget()
	c.setComputeRuntimeExecutionTarget(target)
	familyID := "auth:stopped"
	if _, err := c.runtimeOperations.beginAcquire(familyID, familyID, "auth_operation", target); err != nil {
		t.Fatal(err)
	}
	if _, err := c.runtimeOperations.finishAcquire(familyID, true, nil); err != nil {
		t.Fatal(err)
	}
	transport := &runtimeTransport{done: make(chan struct{})}
	transport.send = func(_ context.Context, request message) error {
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{
			"allocation_authority": stringParam(target, "allocation_id"),
			"status":               "EXECUTION_LIST_STATUS_STOPPED",
		}})
		return nil
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()

	c.reconcileRuntimeOperationRights(context.Background())
	if rights := c.runtimeOperations.snapshot(); len(rights) != 0 {
		t.Fatalf("stopped exact instance retained operation rights: %#v", rights)
	}
}

func TestRuntimeCancelRequestsUseControlSlots(t *testing.T) {
	c := &connector{runtimeAuthSlots: make(chan struct{}, 2), runtimeControlSlots: make(chan struct{}, 2)}
	for range cap(c.runtimeAuthSlots) {
		c.runtimeAuthSlots <- struct{}{}
	}
	for _, request := range []message{
		{Method: "runtime_auth_input_cancel"},
		{Method: "session_migration_prepare", Params: map[string]any{"cancel": true}},
	} {
		slots, capacityErr := c.acquireComputeRuntimeRequest(request)
		if slots != c.runtimeControlSlots || capacityErr != "" {
			t.Fatalf("cancel was not admitted through control slots: request=%+v error=%q", request, capacityErr)
		}
		<-slots
	}
	if slots, _ := c.acquireComputeRuntimeRequest(message{Method: "session_migration_prepare"}); slots != nil {
		t.Fatal("normal migration prepare bypassed saturated operation slots")
	}
}

func TestComputeRuntimeInputLoopStopsOnRetiredIdentityOrUnsupportedProtocol(t *testing.T) {
	for _, reason := range []string{"stale_epoch", "invalid_runtime_handshake", "unknown_protocol_error"} {
		t.Run(reason, func(t *testing.T) {
			var connections atomic.Int32
			upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				connections.Add(1)
				if _, _, err := conn.ReadMessage(); err != nil {
					return
				}
				_ = conn.WriteJSON(map[string]any{"type": "runtime.error", "error": reason})
			}))
			defer server.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			c := &connector{cfg: testComputeRuntimeConfig(server.URL)}
			done := make(chan struct{})
			go func() { c.computeRuntimeInputLoop(ctx); close(done) }()
			select {
			case <-done:
				if got := connections.Load(); got != 1 {
					t.Fatalf("terminal rejection retried %d times", got)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("terminal rejection did not stop Runtime recovery")
			}
		})
	}
}
