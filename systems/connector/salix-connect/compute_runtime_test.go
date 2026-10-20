package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
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
		computeRuntimeKind:           "station",
		computeRuntimeProvider:       "codex",
		computeRuntimeTenantID:       "tenant",
		computeRuntimeProjectID:      "project",
	}
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
			"runtime_kind":        "station",
			"connection_epoch":    "7",
			"features":            []string{"runtime.input.v1", "runtime.event.v1"},
			"input_cursor":        "",
			"event_cursor":        "",
			"token":               "runtime-token",
		}); err != nil {
			serverErrors <- err
			return
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

	serverHealthy := func() {
		select {
		case err := <-serverErrors:
			t.Fatalf("runtime test server: %v", err)
		default:
		}
	}
	waitForCondition(t, "the input loop to retry the lost handshake", func() bool {
		serverHealthy()
		return connectionCount.Load() >= 2
	})
	waitForCondition(t, "the bootstrap token to leave the environment", func() bool {
		serverHealthy()
		_, ok := os.LookupEnv("SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN")
		return !ok
	})

	cancel()
	<-done
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
			"runtime_kind":        "station",
			"connection_epoch":    "7",
			"features":            []string{"runtime.input.v1", "runtime.event.v1"},
			"input_cursor":        "",
			"event_cursor":        "",
			"token":               "runtime-token",
		}); err != nil {
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
	}

	select {
	case got := <-authorizations:
		if got != "Bearer runtime-token" {
			t.Fatalf("reconnect authorization = %q", got)
		}
	case err := <-serverErrors:
		t.Fatalf("runtime test server: %v", err)
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
	}

	cancel()
	<-done
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
	}

	cancel()
	_ = ws.Close()
	<-done
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
	}
	if meetingJoins.Load() != 1 {
		t.Fatalf("meeting join count = %d", meetingJoins.Load())
	}

	cancel()
	close(hold)
	<-done
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

	response := <-reply
	if response.Type != "response" || response.ID != "event-1" {
		t.Fatalf("response = %#v", response)
	}

	close(release)
	cancel()
	<-done
}

type errMissingRuntimeAuthorization struct{}

func (errMissingRuntimeAuthorization) Error() string { return "missing runtime authorization" }

type errInvalidRuntimeHello struct{}

func (errInvalidRuntimeHello) Error() string { return "invalid runtime hello" }

type errUnexpectedRuntimeAuthorization struct{}

func (errUnexpectedRuntimeAuthorization) Error() string { return "unexpected runtime authorization" }

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
			<-done
			if got := connections.Load(); got != 1 {
				t.Fatalf("terminal rejection retried %d times", got)
			}
		})
	}
}
