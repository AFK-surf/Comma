package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	mathrand "math/rand/v2"

	"github.com/gorilla/websocket"
)

func TestCurrentBuildInfoPublishesDiagnosticReleaseWithoutTargetRevision(t *testing.T) {
	originalReleaseID := buildReleaseID
	t.Cleanup(func() { buildReleaseID = originalReleaseID })
	buildReleaseID = "server-bound-test"

	payload, err := json.Marshal(currentBuildInfo())
	if err != nil {
		t.Fatal(err)
	}
	var metadata map[string]any
	if err := json.Unmarshal(payload, &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata["release_id"] != "server-bound-test" {
		t.Fatalf("release_id = %#v", metadata["release_id"])
	}
	if _, exists := metadata["target_revision"]; exists {
		t.Fatalf("binary metadata retains target_revision: %#v", metadata)
	}
}

func TestHelperRuntimeMetadataConnector(t *testing.T) {
	mode := os.Getenv("SALIX_TEST_RUNTIME_METADATA_CONNECTOR")
	if mode != "legacy" && mode != "malformed" {
		t.Skip("helper process only")
	}
	server, token := os.Getenv("SALIX_TEST_RUNTIME_METADATA_SERVER"), os.Getenv("SALIX_TEST_RUNTIME_METADATA_TOKEN")
	alias := os.Getenv("SALIX_TEST_RUNTIME_METADATA_ALIAS")
	u, err := url.Parse(strings.TrimRight(server, "/") + "/v1/connect")
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme == "http" {
		u.Scheme = "ws"
	} else if u.Scheme == "https" {
		u.Scheme = "wss"
	}
	query := u.Query()
	query.Set("name", "Legacy "+alias)
	query.Set("alias", alias)
	u.RawQuery = query.Encode()
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	header.Set(connectorInstanceHeader, mode+"-runtime-observability-e2e")
	ws, response, err := websocket.DefaultDialer.Dial(u.String(), header)
	if err != nil {
		if response != nil {
			t.Fatalf("metadata connector handshake status=%d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	defer ws.Close()
	var connected message
	if err := ws.ReadJSON(&connected); err != nil || connected.Type != "connected" {
		t.Fatalf("metadata connector greeting=%#v err=%v", connected, err)
	}
	capabilities := map[string]any{"legacy_runtime_observability_e2e": true}
	if mode == "malformed" {
		ids := strings.Split(os.Getenv("SALIX_TEST_RUNTIME_METADATA_SESSION_IDS"), ",")
		identity := os.Getenv("SALIX_TEST_RUNTIME_METADATA_IDENTITY")
		capabilities = map[string]any{
			"runtime_probe": true, "valid_runtime_metadata_e2e": true,
			"agent_runtimes": []any{map[string]any{
				"kind": "external", "provider": "codex", "command": identity,
				"identity_material": identity,
				"session_snapshot": map[string]any{
					"schema_version": 1, "observed_at": runtimeAuthTestObservedAt,
					"session_count": len(ids), "session_ids": ids, "truncated": false,
				},
			}},
		}
	}
	var writeMu sync.Mutex
	write := func(payload any) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return ws.WriteJSON(payload)
	}
	if err := write(map[string]any{"type": "metadata", "skills": []any{}, "capabilities": capabilities}); err != nil {
		t.Fatal(err)
	}
	if ready := os.Getenv("SALIX_TEST_RUNTIME_METADATA_READY"); ready != "" {
		if err := os.WriteFile(ready, []byte("ready\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if mode == "malformed" {
		go func() {
			waitForFakeMarker(os.Getenv("SALIX_TEST_RUNTIME_METADATA_GATE"))
			_ = write(map[string]any{
				"type": "metadata", "skills": []any{},
				"capabilities": map[string]any{
					"invalid_runtime_metadata_e2e": true,
					"agent_runtimes":               []any{42},
				},
			})
			_ = write(message{Type: "heartbeat"})
			_ = os.WriteFile(os.Getenv("SALIX_TEST_RUNTIME_METADATA_SENT"), []byte("sent\n"), 0o600)
		}()
	}
	for {
		var incoming message
		if err := ws.ReadJSON(&incoming); err != nil {
			return
		}
		if incoming.Type == "heartbeat" {
			if err := write(message{Type: "heartbeat"}); err != nil {
				return
			}
		}
	}
}

type blockingCloser struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

type blockingCloseWriteCloser struct {
	*blockingCloser
}

func (closer *blockingCloseWriteCloser) Write(data []byte) (int, error) {
	return len(data), nil
}

func dialVMWebSocket(t *testing.T, wsURL string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	var metadata message
	if err := ws.ReadJSON(&metadata); err != nil || metadata.Type != "metadata" {
		_ = ws.Close()
		t.Fatalf("metadata=%#v err=%v", metadata, err)
	}
	return ws
}

// testLongAgo is a time that every budget, TTL and deadline in these tests
// has long passed, even on a synctest bubble's clock (which starts in 2000);
// testFarFuture is one that none of them reaches. Tests use them instead of
// the machine clock.
var (
	testLongAgo   = time.Date(1990, time.January, 1, 0, 0, 0, 0, time.UTC)
	testFarFuture = time.Date(2100, time.January, 1, 0, 0, 0, 0, time.UTC)
)

// incompressibleBytes fills data with a fixed pseudorandom stream: the same
// bytes in every run, and as incompressible as random ones.
func incompressibleBytes(data []byte) {
	_, _ = mathrand.NewChaCha8([32]byte{}).Read(data)
}

// waitForCondition returns once condition holds. The wait has no deadline of
// its own: the go test timeout stops a test that never sees it.
func waitForCondition(t *testing.T, description string, condition func() bool) {
	t.Helper()
	t.Logf("waiting for %s", description)
	for !condition() {
		time.Sleep(time.Millisecond)
	}
}

// waitUntilParked returns once a goroutine with fn on its stack is parked in a
// state that starts with state, as a goroutine dump names it
// ("sync.Mutex.Lock", "select", "chan receive"; "" for any wait). It reads the
// goroutine stacks instead of a clock: when it returns, that goroutine has
// reached the wait.
func waitUntilParked(t *testing.T, state, fn string) {
	t.Helper()
	waitUntilParkedCount(t, state, fn, 1)
}

// waitUntilParkedCount is waitUntilParked for count goroutines at once.
func waitUntilParkedCount(t *testing.T, state, fn string, count int) {
	t.Helper()
	waitForParked(t, state, count, func(frames string) bool { return strings.Contains(frames, fn) })
}

// waitForParked returns once count goroutines whose frames match are parked in
// state.
func waitForParked(t *testing.T, state string, count int, match func(frames string) bool) {
	t.Helper()
	buf := make([]byte, 1<<20)
	for {
		n := runtime.Stack(buf, true)
		if n == len(buf) {
			buf = make([]byte, 2*len(buf))
			continue
		}
		parked := 0
		for _, goroutine := range strings.Split(string(buf[:n]), "\n\n") {
			header, frames, _ := strings.Cut(goroutine, "\n")
			waiting := !strings.Contains(header, "[running") && !strings.Contains(header, "[runnable")
			if waiting && strings.Contains(header, "["+state) && match(frames) {
				parked++
			}
		}
		if parked >= count {
			return
		}
		runtime.Gosched()
	}
}

func dispatchForTest(
	c *connector,
	ctx context.Context,
	id, method string,
	params map[string]any,
	send func(message) error,
) (any, error) {
	session := newConnectionSession(c, ctx, func(_ context.Context, m message) error { return send(m) }, nil)
	defer session.close(context.Canceled)
	return c.dispatchSession(ctx, session, id, method, params)
}

func activateRuntimeTransportForTest(c *connector, send func(message) error) func() {
	return c.activateRuntimeTransport(func(_ context.Context, m message) error {
		return send(m)
	})
}

func (closer *blockingCloser) Close() error {
	closer.once.Do(func() { close(closer.started) })
	<-closer.release
	return nil
}

func TestRunRemoteOnceRepliesToHeartbeat(t *testing.T) {
	isolateHostRuntimeCommands(t)

	messages := make(chan message, 2)
	upgrader := websocket.Upgrader{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/connect" {
			http.NotFound(w, r)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			http.Error(w, "bad authorization", http.StatusUnauthorized)
			return
		}

		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer ws.Close()

		var meta message
		if err := ws.ReadJSON(&meta); err != nil {
			t.Errorf("read metadata: %v", err)
			return
		}
		messages <- meta

		if err := ws.WriteJSON(message{Type: "heartbeat"}); err != nil {
			t.Errorf("write heartbeat: %v", err)
			return
		}

		var rawReply map[string]json.RawMessage
		if err := ws.ReadJSON(&rawReply); err != nil {
			t.Errorf("read heartbeat reply: %v", err)
			return
		}
		if _, polluted := rawReply["skills"]; polluted {
			t.Errorf("heartbeat carried metadata-only skills: %s", rawReply["skills"])
			return
		}
		var reply message
		encodedReply, _ := json.Marshal(rawReply)
		if err := json.Unmarshal(encodedReply, &reply); err != nil {
			t.Errorf("decode heartbeat reply: %v", err)
			return
		}
		messages <- reply

		_ = ws.WriteMessage(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		)
	}))
	defer server.Close()

	connector, err := newConnector(config{
		server: server.URL,
		token:  "test-token",
		name:   "laptop",
		root:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	errs := make(chan error, 1)
	go func() {
		errs <- connector.runRemoteOnce(context.Background())
	}()

	meta := receiveMessage(t, messages)
	if meta.Type != "metadata" {
		t.Fatalf("first connector frame type = %q, want metadata", meta.Type)
	}

	reply := receiveMessage(t, messages)
	if reply.Type != "heartbeat" {
		t.Fatalf("heartbeat reply type = %q, want heartbeat", reply.Type)
	}

	<-errs
}

func TestRemoteWebSocketBlockedDataSendFailsWithinWriteDeadline(t *testing.T) {
	isolateHostRuntimeCommands(t)

	previousTimeout := webSocketWriteTimeout
	webSocketWriteTimeout = 50 * time.Millisecond
	defer func() { webSocketWriteTimeout = previousTimeout }()

	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "large.bin"), make([]byte, maxFile), 0o600); err != nil {
		t.Fatal(err)
	}

	// The Server asks for a large file and never reads the answer. Over the
	// in-memory network the send blocks at once, and the bubble's clock
	// reaches the write deadline, whatever the kernel would have buffered.
	synctest.Test(t, func(t *testing.T) {
		upgrader := websocket.Upgrader{}
		requestSent := make(chan struct{})
		releaseServer := make(chan struct{})
		defer close(releaseServer)
		server, dial := memoryServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ws, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer ws.Close()
			var metadata message
			if ws.ReadJSON(&metadata) != nil {
				return
			}
			if ws.WriteJSON(message{
				ID: "blocked-send", Type: "request", Method: "read",
				Params: map[string]any{"path": "large.bin"},
			}) != nil {
				return
			}
			close(requestSent)
			<-releaseServer
		}))

		connector, err := newConnector(config{
			root: root, name: "blocked-data-send", server: server, dial: dial,
			token: "token", systemInfoInterval: 0,
		})
		if err != nil {
			t.Fatal(err)
		}
		// The connector's workers end with the bubble.
		defer close(connector.cleanupQueue)
		result := make(chan error, 1)
		go func() { result <- connector.runRemoteOnce(context.Background()) }()
		<-requestSent
		if err := <-result; err == nil {
			t.Fatal("blocked websocket send returned no error")
		}
	})
}

func TestRuntimeAgentCarrierContract(t *testing.T) {
	for _, carrier := range []string{"connected_device", "cloudflare", "agent_vmm"} {
		t.Run(carrier, func(t *testing.T) {
			isolateHostRuntimeCommands(t)
			agent, err := newConnector(config{
				runtimeAgent:       true,
				root:               t.TempDir(),
				name:               "compute-runtime-agent-" + carrier,
				systemInfoInterval: 0,
			})
			if err != nil {
				t.Fatalf("new runtime agent: %v", err)
			}

			server := httptest.NewServer(agent.vmHTTPHandler(context.Background()))
			defer server.Close()
			ready := httpGetJSON(t, server.URL+"/readyz")
			if ready["ready"] != true || ready["workspace_marked"] != true {
				t.Fatalf("runtime agent ready payload = %#v", ready)
			}

			wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
			ws := dialVMWebSocket(t, wsURL)
			defer ws.Close()
			if err := ws.WriteJSON(message{
				ID: "carrier-contract", Type: "request", Method: "exec",
				Params: map[string]any{"command": "printf " + carrier, "timeout": 5},
			}); err != nil {
				t.Fatal(err)
			}
			var reply message
			if err := ws.ReadJSON(&reply); err != nil {
				t.Fatal(err)
			}
			result, ok := reply.Result.(map[string]any)
			if reply.ID != "carrier-contract" || reply.Type != "response" || !ok || result["stdout"] != carrier {
				t.Fatalf("runtime agent %s reply = %#v", carrier, reply)
			}
		})
	}
}

func newVMWebSocketTestConnector(t *testing.T, cfg config) (*connector, error) {
	t.Helper()
	connector, err := newConnector(cfg)
	if err == nil {
		t.Cleanup(connector.closeRuntimes)
	}
	return connector, err
}

// handlerReturns wraps handler. The channel receives each time a request's
// handler has returned: for a VM WebSocket, once its generation reads no more
// frames.
func handlerReturns(handler http.Handler) (http.Handler, <-chan struct{}) {
	returned := make(chan struct{}, 8)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() { returned <- struct{}{} }()
		handler.ServeHTTP(w, r)
	}), returned
}

func isolateHostRuntimeCommands(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	previousBundlePaths := codexAppBundleCommandPaths
	codexAppBundleCommandPaths = func() []string { return nil }
	t.Cleanup(func() { codexAppBundleCommandPaths = previousBundlePaths })
}

// Tests discover Claude only through PATH and the per-user install location,
// which follows each test's HOME, never through a host-wide install such as
// Homebrew's.
func init() {
	claudeCommandPaths = func() []string {
		home, _ := os.UserHomeDir()
		return []string{filepath.Join(home, ".local", "bin", "claude")}
	}
}

func TestVMServerHealthReadyAndConnect(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer:           true,
		root:               t.TempDir(),
		name:               "cloud-vm",
		systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	health := httpGetJSON(t, server.URL+"/healthz")
	if health["ok"] != true {
		t.Fatalf("health ok = %v", health["ok"])
	}
	ready := httpGetJSON(t, server.URL+"/readyz")
	if ready["ready"] != true || ready["workspace_marked"] != true ||
		ready["connector_build_revision"] != connectorBuildRevision {
		t.Fatalf("ready payload = %#v", ready)
	}

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial vm connect: %v", err)
	}
	defer ws.Close()

	var meta message
	if err := ws.ReadJSON(&meta); err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	if meta.Type != "metadata" {
		t.Fatalf("first frame = %q, want metadata", meta.Type)
	}

	if err := ws.WriteJSON(message{Type: "connected", ConnectorRunID: "run-vm"}); err != nil {
		t.Fatalf("write connected: %v", err)
	}
	if err := ws.WriteJSON(message{
		ID:     "req-1",
		Type:   "request",
		Method: "exec",
		Params: map[string]any{"command": "printf ok", "timeout": 5},
	}); err != nil {
		t.Fatalf("write exec request: %v", err)
	}

	var reply message
	if err := ws.ReadJSON(&reply); err != nil {
		t.Fatalf("read exec reply: %v", err)
	}
	if reply.ID != "req-1" || reply.Type != "response" {
		t.Fatalf("reply = %#v", reply)
	}
	result, ok := reply.Result.(map[string]any)
	if !ok || result["stdout"] != "ok" {
		t.Fatalf("exec result = %#v", reply.Result)
	}
}

func TestVMWebSocketMetadataAlwaysCarriesEmptySkills(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: t.TempDir(), name: "metadata-skills", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var raw map[string]json.RawMessage
	if err := ws.ReadJSON(&raw); err != nil {
		t.Fatal(err)
	}
	skills, present := raw["skills"]
	if !present {
		t.Fatal("metadata omitted skills, so reconnect cannot clear stale server skills")
	}
	var decoded []any
	if err := json.Unmarshal(skills, &decoded); err != nil || len(decoded) != 0 {
		t.Fatalf("skills=%s decoded=%#v err=%v", skills, decoded, err)
	}
}

func TestVMWebSocketGenerationsDoNotLeakParentContextWatchers(t *testing.T) {
	// Keep host-installed agent binaries out of the connector inventory probe;
	// this test exercises WebSocket generation cleanup, not runtime readiness.
	isolateHostRuntimeCommands(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: t.TempDir(), name: "generation-watchers", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(ctx))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	baseline := connectionWatcherCount(t)

	for index := 0; index < 20; index++ {
		ws := dialVMWebSocket(t, wsURL)
		if err := ws.Close(); err != nil {
			t.Fatal(err)
		}
		waitForCondition(t, "closed WebSocket generation", func() bool {
			connector.connectionMu.Lock()
			defer connector.connectionMu.Unlock()
			return connector.activeConnection == nil
		})
	}

	waitForCondition(t, "connection parent-context watchers to drain", func() bool {
		return connectionWatcherCount(t) <= baseline
	})
}

func connectionWatcherCount(t *testing.T) int {
	t.Helper()
	var stacks bytes.Buffer
	if err := pprof.Lookup("goroutine").WriteTo(&stacks, 2); err != nil {
		t.Fatal(err)
	}
	return bytes.Count(stacks.Bytes(), []byte("newConnectionSession.func1"))
}

func TestVMWebSocketReplacementClosesOldGenerationAndServesNewRPC(t *testing.T) {
	isolateHostRuntimeCommands(t)

	lateMarker := filepath.Join(t.TempDir(), "late-old-request")
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer:           true,
		root:               t.TempDir(),
		name:               "replacement-vm",
		systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	handler, served := handlerReturns(connector.vmHTTPHandler(context.Background()))
	server := httptest.NewServer(handler)
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	oldWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer oldWS.Close()
	var metadata message
	if err := oldWS.ReadJSON(&metadata); err != nil || metadata.Type != "metadata" {
		t.Fatalf("old metadata: %#v err=%v", metadata, err)
	}
	if err := oldWS.WriteJSON(message{Type: "connected", ConnectorRunID: "old-run"}); err != nil {
		t.Fatal(err)
	}
	if err := oldWS.WriteJSON(message{
		ID:     "old-exec",
		Type:   "request",
		Method: "exec",
		Params: map[string]any{"command": "sleep 30", "timeout": 30},
	}); err != nil {
		t.Fatal(err)
	}

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	metadata = message{}
	if err := newWS.ReadJSON(&metadata); err != nil || metadata.Type != "metadata" {
		t.Fatalf("new metadata: %#v err=%v", metadata, err)
	}
	_ = oldWS.WriteJSON(message{
		ID: "late-old-exec", Type: "request", Method: "exec",
		Params: map[string]any{"command": "printf late > " + shellQuote(lateMarker)},
	})
	if err := newWS.WriteJSON(message{Type: "connected", ConnectorRunID: "new-run"}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.WriteJSON(message{
		ID:     "new-list",
		Type:   "request",
		Method: "process_list",
	}); err != nil {
		t.Fatal(err)
	}
	var reply message
	if err := newWS.ReadJSON(&reply); err != nil {
		t.Fatal(err)
	}
	if reply.ID != "new-list" || reply.Type != "response" {
		t.Fatalf("replacement reply = %#v", reply)
	}

	// The replacement closes the old socket; a socket left open would block
	// this read until the go test timeout.
	if err := oldWS.ReadJSON(&reply); err == nil {
		t.Fatalf("old generation remained readable after replacement: %#v", reply)
	}
	if runID, _, _ := connector.connectionIdentity(); runID != "new-run" {
		t.Fatalf("stale generation replaced active identity: %q", runID)
	}
	// The old generation's handler has returned, so it reads no more frames.
	// A request it admitted would hold an operation record.
	<-served
	connector.requestMu.Lock()
	_, admitted := connector.requestOperations["late-old-exec"]
	connector.requestMu.Unlock()
	if admitted || fileExists(lateMarker) {
		t.Fatal("old generation admitted a request after replacement metadata was visible")
	}
}

func TestVMWebSocketReplacementRejectsOldRequestAlreadyPastReadLoopActiveCheck(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	marker := filepath.Join(root, "old-window-marker")
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: root, name: "replacement-admission-window", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	admissionEntered := make(chan struct{})
	releaseAdmission := make(chan struct{})
	replacementPublished := make(chan struct{})
	releaseReplacement := make(chan struct{})
	connector.beforeRequestAdmission = func(_ *connectionSession, msg message) {
		if msg.ID == "old-window-write" {
			close(admissionEntered)
			<-releaseAdmission
		}
	}
	connector.afterConnectionPublished = func(_ *connectionSession) {
		close(replacementPublished)
		<-releaseReplacement
	}

	handler, served := handlerReturns(connector.vmHTTPHandler(context.Background()))
	server := httptest.NewServer(handler)
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	oldWS := dialVMWebSocket(t, wsURL)
	defer oldWS.Close()
	if err := oldWS.WriteJSON(message{
		ID: "old-window-write", Type: "request", Method: "write",
		Params: map[string]any{"path": "old-window-marker", "content": "stale"},
	}); err != nil {
		t.Fatal(err)
	}
	<-admissionEntered

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	<-replacementPublished
	close(releaseAdmission)
	// The old generation's handler returns after admission has decided on the
	// write. A write it admitted would hold an operation record.
	<-served
	connector.requestMu.Lock()
	_, admitted := connector.requestOperations["old-window-write"]
	connector.requestMu.Unlock()
	if admitted || fileExists(marker) {
		t.Fatal("old generation produced a side effect after replacement was published")
	}
	close(releaseReplacement)
	var frame message
	if err := newWS.ReadJSON(&frame); err != nil || frame.Type != "metadata" {
		t.Fatalf("replacement metadata=%#v err=%v", frame, err)
	}
	if err := newWS.WriteJSON(message{ID: "new-after-window", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil || frame.ID != "new-after-window" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
}

func TestVMWebSocketReplacementClosesOldReplySinkBeforePublishingNewGeneration(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	fifo := filepath.Join(root, "blocked-read.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: root, name: "replacement-reply-sink", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	replacementPublished := make(chan struct{})
	releaseReplacement := make(chan struct{})
	connector.afterConnectionPublished = func(_ *connectionSession) {
		close(replacementPublished)
		<-releaseReplacement
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	oldWS := dialVMWebSocket(t, wsURL)
	defer oldWS.Close()
	if err := oldWS.WriteJSON(message{
		ID: "old-blocked-read", Type: "request", Method: "read",
		Params: map[string]any{"path": "blocked-read.fifo"},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "old request admission", func() bool { return len(connector.requestSlots) == 1 })

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	<-replacementPublished

	writer, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("finished")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "actor-owned old request completion", func() bool { return len(connector.requestSlots) == 0 })

	// The replacement closed the old socket before it was published; a socket
	// left open would block this read until the go test timeout.
	var frame message
	if err := oldWS.ReadJSON(&frame); err == nil {
		t.Fatalf("old reply sink remained writable after replacement publication: %#v", frame)
	}
	close(releaseReplacement)
	if err := newWS.ReadJSON(&frame); err != nil || frame.Type != "metadata" {
		t.Fatalf("replacement metadata=%#v err=%v", frame, err)
	}
	if err := newWS.WriteJSON(message{ID: "new-after-old-complete", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil || frame.ID != "new-after-old-complete" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
}

func TestVMWebSocketReconnectDoesNotCancelActorOwnedExec(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	started := filepath.Join(root, "exec-started")
	marker := filepath.Join(root, "exec-finished")
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	command := "printf started > " + shellQuote(started) + "; sleep 0.4; printf finished > " + shellQuote(marker)
	if err := ws.WriteJSON(message{
		ID: "actor-owned-exec", Type: "request", Method: "exec",
		Params: map[string]any{"command": command, "timeout": 30},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "actor-owned exec start", func() bool { return fileExists(started) })
	if err := ws.Close(); err != nil {
		t.Fatal(err)
	}
	replacement := dialVMWebSocket(t, wsURL)
	defer replacement.Close()
	if err := replacement.WriteJSON(message{ID: "after-reconnect", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	var frame message
	if err := replacement.ReadJSON(&frame); err != nil || frame.ID != "after-reconnect" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
	waitForCondition(t, "actor-owned exec completion", func() bool { return fileExists(marker) })
	waitForCondition(t, "actor-owned exec cleanup", func() bool { return len(connector.requestSlots) == 0 })
}

func TestVMReplacementDuringComputerUseLaunchDoesNotPoisonConnector(t *testing.T) {
	isolateHostRuntimeCommands(t)

	if runtime.GOOS != "darwin" {
		t.Skip("computer_use is macOS-only")
	}
	root := t.TempDir()
	helperApp := filepath.Join(root, "Comma Computer Use.app")
	daemon := filepath.Join(helperApp, "Contents", "MacOS", "CommaComputerUseDaemon")
	if err := os.MkdirAll(filepath.Dir(daemon), 0o755); err != nil {
		t.Fatal(err)
	}
	// The launch first asks the bundled daemon to prepare the application.
	if err := os.WriteFile(daemon, []byte("#!/bin/sh\nprintf '%s\\n' "+shellQuote(helperApp)+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	started := filepath.Join(root, "open-started")
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	openScript := filepath.Join(binDir, "open")
	if err := os.WriteFile(openScript, []byte("#!/bin/sh\nprintf started > \"$SALIX_OPEN_STARTED\"\n/bin/sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("SALIX_OPEN_STARTED", started)
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: root, systemInfoInterval: 0,
		computerUseHelperApp:  helperApp,
		computerUseSocketPath: filepath.Join(root, "computer-use.sock"),
	})
	if err != nil {
		t.Fatal(err)
	}
	handler, served := handlerReturns(connector.vmHTTPHandler(context.Background()))
	server := httptest.NewServer(handler)
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	oldWS := dialVMWebSocket(t, wsURL)
	defer oldWS.Close()
	if err := oldWS.WriteJSON(message{
		ID: "blocked-computer-use", Type: "request", Method: "computer_use",
		Params: map[string]any{"action": "status"},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "computer_use helper launch", func() bool { return fileExists(started) })
	replacement := dialVMWebSocket(t, wsURL)
	defer replacement.Close()
	// The old generation's handler returns after its workers drained, or
	// after it reported them stuck.
	<-served
	if fatal := connector.connectorFatal(); fatal != nil {
		t.Fatalf("canceled computer_use launch poisoned connector: %v", fatal)
	}
	if err := replacement.WriteJSON(message{ID: "after-computer-use-replacement", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	var frame message
	if err := replacement.ReadJSON(&frame); err != nil || frame.ID != "after-computer-use-replacement" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
}

func TestVMWebSocketControlFrameOvertakesQueuedDataFrames(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	largePath := filepath.Join(root, "large.txt")
	if err := os.WriteFile(largePath, bytes.Repeat([]byte("x"), maxFile), 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	defer ws.Close()
	if tcp, ok := ws.UnderlyingConn().(*net.TCPConn); ok {
		_ = tcp.SetReadBuffer(1024)
	}

	for index := 0; index < 3; index++ {
		if err := ws.WriteJSON(message{
			ID: fmt.Sprintf("large-%d", index), Type: "request", Method: "read",
			Params: map[string]any{"path": "large.txt"},
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitForCondition(t, "three data responses to block or queue", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.requestSlots) == 3
	})
	if err := ws.WriteJSON(message{Type: "heartbeat"}); err != nil {
		t.Fatal(err)
	}

	dataBeforeHeartbeat := 0
	for {
		var frame message
		if err := ws.ReadJSON(&frame); err != nil {
			t.Fatal(err)
		}
		if frame.Type == "heartbeat" {
			break
		}
		if frame.Type == "response" && strings.HasPrefix(frame.ID, "large-") {
			dataBeforeHeartbeat++
		}
	}
	if dataBeforeHeartbeat > 1 {
		t.Fatalf("heartbeat followed %d data frames; at most the already-active frame may lead it", dataBeforeHeartbeat)
	}
	_ = ws.Close()
	waitForCondition(t, "queued data responses to finish", func() bool {
		return len(connector.requestSlots) == 0
	})
}

func TestVMWebSocketRealBlockingRequestsHitAdmissionLimit(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	paths := make([]string, maxConcurrentRequests)
	for index := range paths {
		paths[index] = filepath.Join(root, fmt.Sprintf("blocked-%d.fifo", index))
		if err := syscall.Mkfifo(paths[index], 0o600); err != nil {
			t.Fatal(err)
		}
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	// A request is done once it marked the workspace dirty, after its slot is
	// free: the test's directory goes only after that write.
	finished := make(chan string, len(paths))
	connector.afterRequestFinished = func(msg message) {
		if strings.HasPrefix(msg.ID, "blocked-") {
			finished <- msg.ID
		}
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	defer ws.Close()

	for index := range paths {
		if err := ws.WriteJSON(message{
			ID: fmt.Sprintf("blocked-%d", index), Type: "request", Method: "read",
			Params: map[string]any{"path": filepath.Base(paths[index])},
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitForCondition(t, "all filesystem request slots to fill", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.requestSlots) == maxConcurrentRequests
	})
	if err := ws.WriteJSON(message{
		ID: "over-limit", Type: "request", Method: "stat", Params: map[string]any{"path": "."},
	}); err != nil {
		t.Fatal(err)
	}
	var frame message
	if err := ws.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if frame.ID != "over-limit" || frame.Type != "error" || !strings.Contains(frame.Error, "connector request capacity exhausted") {
		t.Fatalf("overload frame=%#v", frame)
	}

	var release sync.WaitGroup
	for _, path := range paths {
		release.Add(1)
		go func() {
			defer release.Done()
			writer, openErr := os.OpenFile(path, os.O_WRONLY, 0)
			if openErr == nil {
				_, _ = writer.Write([]byte("release"))
				_ = writer.Close()
			}
		}()
	}
	release.Wait()
	for range paths {
		<-finished
	}
	if len(connector.requestSlots) != 0 {
		t.Fatalf("request slots still held: %d", len(connector.requestSlots))
	}
}

func TestVMWebSocketRealBlockingStreamsHitAdmissionLimit(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	paths := make([]string, maxConcurrentStreamWrites+1)
	readers := make([]*os.File, 0, len(paths))
	for index := range paths {
		paths[index] = filepath.Join(root, fmt.Sprintf("stream-%d.fifo", index))
		if err := syscall.Mkfifo(paths[index], 0o600); err != nil {
			t.Fatal(err)
		}
		reader, err := os.OpenFile(paths[index], os.O_RDONLY|syscall.O_NONBLOCK, 0)
		if err != nil {
			t.Fatal(err)
		}
		readers = append(readers, reader)
	}
	defer func() {
		for _, reader := range readers {
			_ = reader.Close()
		}
	}()
	connector, err := newConnector(config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	t.Cleanup(func() {
		_ = ws.Close()
		server.Close()
		connector.closeRuntimes()
	})

	for index := range paths {
		id := fmt.Sprintf("stream-%d", index)
		if err := ws.WriteJSON(message{
			ID: id, Type: "request", Method: "write_stream",
			Params: map[string]any{"path": filepath.Base(paths[index])},
		}); err != nil {
			t.Fatal(err)
		}
		var ready message
		if err := ws.ReadJSON(&ready); err != nil || ready.ID != id || ready.Type != "response" {
			t.Fatalf("ready=%#v err=%v", ready, err)
		}
	}
	payload := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte("x"), 1024*1024))
	for index := 0; index < maxConcurrentStreamWrites; index++ {
		if err := ws.WriteJSON(message{
			ID: fmt.Sprintf("stream-%d", index), Type: "stream",
			Stream: &streamData{Channel: "data", Seq: 1, Data: payload},
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitForCondition(t, "all stream worker slots to fill", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.activeConnection.streamSlots) == maxConcurrentStreamWrites
	})
	overLimitID := fmt.Sprintf("stream-%d", maxConcurrentStreamWrites)
	if err := ws.WriteJSON(message{
		ID: overLimitID, Type: "stream",
		Stream: &streamData{Channel: "data", Seq: 1, Data: base64.StdEncoding.EncodeToString([]byte("rejected"))},
	}); err != nil {
		t.Fatal(err)
	}
	var frame message
	if err := ws.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if frame.ID != overLimitID || frame.Type != "stream" || !strings.Contains(frame.Error, "connector stream capacity exhausted") {
		t.Fatalf("stream overload frame=%#v", frame)
	}
	for _, reader := range readers {
		_ = reader.Close()
	}
	readers = nil
	waitForCondition(t, "released stream writes to finish", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.activeConnection.streamSlots) == 0
	})
	_ = ws.Close()
	waitForCondition(t, "websocket cleanup to finish", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection == nil
	})
}

func TestVMWebSocketWriteStreamLimitPreservesRejectedTarget(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	rejectedPath := filepath.Join(root, "stream-16.txt")
	if err := os.WriteFile(rejectedPath, []byte("do-not-truncate"), 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	defer ws.Close()

	for index := 0; index <= maxPendingWriteStreams; index++ {
		id := fmt.Sprintf("stream-%d", index)
		if err := ws.WriteJSON(message{
			ID: id, Type: "request", Method: "write_stream",
			Params: map[string]any{"path": id + ".txt"},
		}); err != nil {
			t.Fatal(err)
		}
		var frame message
		if err := ws.ReadJSON(&frame); err != nil || frame.ID != id {
			t.Fatalf("write_stream frame=%#v err=%v", frame, err)
		}
		if index < maxPendingWriteStreams && frame.Type != "response" {
			t.Fatalf("accepted write_stream frame=%#v", frame)
		}
		if index == maxPendingWriteStreams && (frame.Type != "error" || !strings.Contains(frame.Error, "write_stream capacity exhausted")) {
			t.Fatalf("rejected write_stream frame=%#v", frame)
		}
	}
	content, err := os.ReadFile(rejectedPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "do-not-truncate" {
		t.Fatalf("rejected stream truncated target: %q", content)
	}
}

func TestVMWebSocketRequestWatchdogClosesBlockedIOAndReplacementServes(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	fifo := filepath.Join(root, "blocked-read")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	finished := make(chan string, 4)
	connector.afterRequestFinished = func(msg message) { finished <- msg.ID }
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	blockedWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer blockedWS.Close()
	var metadata message
	if err := blockedWS.ReadJSON(&metadata); err != nil {
		t.Fatal(err)
	}
	connector.connectionMu.Lock()
	blockedSession := connector.activeConnection
	blockedSession.deadline = func(message) time.Duration { return 30 * time.Millisecond }
	connector.connectionMu.Unlock()
	if err := blockedWS.WriteJSON(message{
		ID:     "blocked-read",
		Type:   "request",
		Method: "read",
		Params: map[string]any{"path": fifo},
	}); err != nil {
		t.Fatal(err)
	}
	// The read is admitted and blocked opening the FIFO before the
	// replacement connects: a replacement that came first would turn the
	// read away, and nothing would hold the FIFO open for the writer below.
	waitUntilParked(t, "syscall", "(*connector).methodRead(")
	var reply message
	replacement, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close()
	if err := replacement.ReadJSON(&metadata); err != nil {
		t.Fatal(err)
	}
	if err := replacement.WriteJSON(message{ID: "replacement-list", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	if err := replacement.ReadJSON(&reply); err != nil || reply.ID != "replacement-list" || reply.Type != "response" {
		t.Fatalf("replacement RPC reply=%#v err=%v", reply, err)
	}
	// The serving replacement has closed the blocked socket; a socket left
	// open would block this read until the go test timeout.
	if err := blockedWS.ReadJSON(&reply); err == nil {
		t.Fatalf("replacement left the blocked request socket alive: %#v", reply)
	}

	writer, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = writer.Write([]byte("release"))
	_ = writer.Close()

	// Join both request goroutines before returning: each marks the workspace
	// dirty under the connector root after its reply, and returning early races
	// t.TempDir's RemoveAll ("directory not empty").
	pending := map[string]bool{"blocked-read": true, "replacement-list": true}
	for len(pending) > 0 {
		delete(pending, <-finished)
	}
}

func TestVMWebSocketRequestWatchdogHonorsLongRunningMethodTimeout(t *testing.T) {
	isolateHostRuntimeCommands(t)

	previousTimeout := requestExecutionTimeout
	requestExecutionTimeout = 20 * time.Millisecond
	defer func() { requestExecutionTimeout = previousTimeout }()

	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: t.TempDir(), systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var frame message
	if err := ws.ReadJSON(&frame); err != nil || frame.Type != "metadata" {
		t.Fatalf("metadata=%#v err=%v", frame, err)
	}
	if err := ws.WriteJSON(message{
		ID: "long-exec", Type: "request", Method: "exec",
		// The command outlasts the 20 ms watchdog of ordinary methods and ends
		// long before its own timeout.
		Params: map[string]any{"command": "sleep 0.05; printf ok", "timeout": 3600},
	}); err != nil {
		t.Fatal(err)
	}
	if err := ws.ReadJSON(&frame); err != nil || frame.ID != "long-exec" || frame.Type != "response" {
		t.Fatalf("long-running method reply=%#v err=%v", frame, err)
	}
	result, ok := frame.Result.(map[string]any)
	if !ok || result["stdout"] != "ok" {
		t.Fatalf("long-running method result=%#v", frame.Result)
	}
}

func TestVMReplacementKeepsAcceptedProcessWritesButClosesOldReplySink(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	marker := filepath.Join(root, "stdin-markers")
	ready := filepath.Join(root, "process-ready")
	gate := filepath.Join(root, "start-reading")
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	oldWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer oldWS.Close()
	var frame message
	if err := oldWS.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if err := oldWS.WriteJSON(message{
		ID:     "start-delayed-reader",
		Type:   "request",
		Method: "process_start",
		Params: map[string]any{
			"process_name": "delayed-reader",
			"command":      "/bin/sh",
			"args": []any{"-c", "printf ready > " + shellQuote(ready) +
				"; while [ ! -f " + shellQuote(gate) + " ]; do sleep 0.01; done; cat > " + shellQuote(marker)},
		},
	}); err != nil {
		t.Fatal(err)
	}
	if err := oldWS.ReadJSON(&frame); err != nil || frame.Type != "response" {
		t.Fatalf("process_start reply=%#v err=%v", frame, err)
	}
	waitForCondition(t, "managed process readiness", func() bool { return fileExists(ready) })
	large := strings.Repeat("A", 1024*1024)
	if err := oldWS.WriteJSON(message{
		ID: "fill-pipe", Type: "request", Method: "process_write",
		Params: map[string]any{"process_name": "delayed-reader", "data": large},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "first process write to hold the stdin slot", func() bool {
		connector.processMu.Lock()
		proc := connector.processes["delayed-reader"]
		connector.processMu.Unlock()
		return proc != nil && len(proc.stdinSlot) == 1
	})
	if err := oldWS.WriteJSON(message{
		ID: "old-marker", Type: "request", Method: "process_write",
		Params: map[string]any{"process_name": "delayed-reader", "data": "OLD_MARKER\n"},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "queued old process write", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.requestSlots) == 2
	})

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	if err := newWS.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(gate, []byte("open"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := newWS.WriteJSON(message{
		ID: "new-marker", Type: "request", Method: "process_write",
		Params: map[string]any{"process_name": "delayed-reader", "data": "NEW_MARKER\n"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil || frame.ID != "new-marker" || frame.Type != "response" {
		t.Fatalf("new process_write reply=%#v err=%v", frame, err)
	}
	// The replacement closed the old socket; a socket left open would block
	// this read until the go test timeout.
	if err := oldWS.ReadJSON(&frame); err == nil {
		t.Fatalf("old reply sink remained readable after replacement: %#v", frame)
	}
	// cat copies its stdin to the marker. A write lost across the replacement
	// never arrives there, and the go test timeout reports it.
	waitForCondition(t, "both accepted writes to reach the process", func() bool {
		content, _ := os.ReadFile(marker)
		return bytes.Contains(content, []byte("OLD_MARKER")) && bytes.Contains(content, []byte("NEW_MARKER"))
	})
	if err := newWS.WriteJSON(message{
		ID: "stop-reader", Type: "request", Method: "process_stop",
		Params: map[string]any{"process_name": "delayed-reader"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
}

func TestRemoteCleanupFatalStopsReconnectAfterServerDisappears(t *testing.T) {
	isolateHostRuntimeCommands(t)

	upgrader := websocket.Upgrader{}
	firstDone := make(chan struct{})
	var dials int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&dials, 1)
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var metadata message
		if ws.ReadJSON(&metadata) != nil {
			return
		}
		_ = ws.WriteJSON(message{
			ID: "pending-write", Type: "request", Method: "write_stream",
			Params: map[string]any{"path": "pending.bin"},
		})
		var ready message
		if ws.ReadJSON(&ready) != nil {
			return
		}
		_ = ws.Close()
		select {
		case <-firstDone:
		default:
			close(firstDone)
		}
	}))

	connector, err := newConnector(config{
		root: t.TempDir(), name: "fatal-remote", server: server.URL, token: "token",
		reconnect: true, systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	blockedCleanup := &blockingCloser{started: make(chan struct{}), release: make(chan struct{})}
	defer close(blockedCleanup.release)
	connector.enqueueCleanup(blockedCleanup)
	<-blockedCleanup.started
	for index := 0; index < cleanupQueueSize; index++ {
		connector.enqueueCleanup(io.NopCloser(strings.NewReader("occupied")))
	}
	result := make(chan error, 1)
	go func() { result <- connector.runRemote(context.Background()) }()
	<-firstDone
	server.Close()
	err = <-result
	if !isConnectorFatal(err) {
		t.Fatalf("runRemote returned non-terminal error: %T %v", err, err)
	}
	// runRemote has returned, so it dials no more.
	if got := atomic.LoadInt64(&dials); got != 1 {
		t.Fatalf("connector redialed after sticky fatal: dials=%d", got)
	}
}

func TestVMServerArchiveRoundTrip(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newConnector(config{vmServer: true, root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer connector.closeRuntimes()
	// A device upgraded from an earlier release keeps its External Session
	// state directory; it is never archived.
	legacyState := filepath.Join(connector.root, legacyExternalRuntimeDir, "state.db")
	if err := os.MkdirAll(filepath.Dir(legacyState), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyState, []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(connector.root, "hello.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	resp, err := http.Get(server.URL + "/archive")
	if err != nil {
		t.Fatalf("get archive: %v", err)
	}
	raw, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		t.Fatalf("read archive: %v", err)
	}
	if !tarGzContains(t, raw, "hello.txt") {
		t.Fatal("archive did not contain hello.txt")
	}
	if tarGzContains(t, raw, legacyExternalRuntimeDir+"/state.db") || tarGzContains(t, raw, legacyExternalRuntimeDir) {
		t.Fatal("archive included legacy external runtime state")
	}

	restoreRoot := t.TempDir()
	restored, err := newConnector(config{vmServer: true, root: restoreRoot, systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new restore connector: %v", err)
	}
	defer restored.closeRuntimes()
	restoreServer := httptest.NewServer(restored.vmHTTPHandler(context.Background()))
	defer restoreServer.Close()

	req, err := http.NewRequest(http.MethodPut, restoreServer.URL+"/archive", bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("new restore request: %v", err)
	}
	restoreResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore archive: %v", err)
	}
	_ = restoreResp.Body.Close()
	if restoreResp.StatusCode != http.StatusOK {
		t.Fatalf("restore status = %d", restoreResp.StatusCode)
	}
	data, err := os.ReadFile(filepath.Join(restoreRoot, "hello.txt"))
	if err != nil {
		t.Fatalf("read restored file: %v", err)
	}
	if string(data) != "hello" {
		t.Fatalf("restored file = %q", data)
	}

	// An archive from an earlier release may carry External Session state:
	// the rest restores and the legacy state is skipped.
	legacyArchive := makeTarGz(t, []tarEntry{
		{name: legacyExternalRuntimeDir + "/state.db", data: []byte("legacy")},
		{name: legacyExternalRuntimeDir + "/archive-scope.json", data: []byte(`{"scope":"recovery"}`)},
		{name: "after-upgrade.txt", data: []byte("kept")},
	})
	req, _ = http.NewRequest(http.MethodPut, restoreServer.URL+"/archive", bytes.NewReader(legacyArchive))
	restoreResp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore legacy archive: %v", err)
	}
	if restoreResp.StatusCode != http.StatusOK {
		t.Fatalf("restore legacy archive status=%s", restoreResp.Status)
	}
	_ = restoreResp.Body.Close()
	if data, err := os.ReadFile(filepath.Join(restoreRoot, "after-upgrade.txt")); err != nil || string(data) != "kept" {
		t.Fatalf("restored file = %q, %v", data, err)
	}
	if _, err := os.Lstat(filepath.Join(restoreRoot, legacyExternalRuntimeDir)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy external runtime state was restored: %v", err)
	}
}

func TestVMServerArchiveRestoreRejectsSymlinkEscape(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		if runtime.GOOS == "windows" {
			t.Skipf("symlink unavailable: %v", err)
		}
		t.Fatalf("create symlink: %v", err)
	}

	connector, err := newConnector(config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	payload := makeTarGz(t, []tarEntry{{name: "link/pwned.txt", data: []byte("escape")}})
	req, err := http.NewRequest(http.MethodPut, server.URL+"/archive", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("new restore request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore archive: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("restore status = %d, want 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(outside, "pwned.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("outside file stat err = %v, want not exists", err)
	}
}

func TestVMServerArchiveRestoreRejectsOversizedFile(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newConnector(config{vmServer: true, root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	payload := makeTarGz(t, []tarEntry{{name: "too-large.bin", data: bytes.Repeat([]byte("x"), maxArchiveFile+1)}})
	req, err := http.NewRequest(http.MethodPut, server.URL+"/archive", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("new restore request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore archive: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("restore status = %d, want 400", resp.StatusCode)
	}
}

func TestConnectorStatusAdvertisesLocalFileIndexVersion(t *testing.T) {
	statusPath := filepath.Join(t.TempDir(), "connector.status.json")
	c := &connector{cfg: config{statusPath: statusPath}}
	session := c.claimConnection(context.Background(), func(context.Context, message) error {
		return nil
	}, nil)
	defer session.close(context.Canceled)
	if !c.setIdentity(session, "run_v2_status", "dev_v2_status", "connector_v2_status", "user_v2_status", 17) {
		t.Fatal("failed to bind test connection identity")
	}

	c.writeStatus("connected", "wss://salix.example.test", nil)

	data, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("read connector status: %v", err)
	}
	var status map[string]any
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("decode connector status: %v", err)
	}
	if got := status["state"]; got != "connected" {
		t.Fatalf("state = %#v, want connected", got)
	}
	if got := status["local_file_index_version"]; got != float64(2) {
		t.Fatalf("local_file_index_version = %#v, want 2", got)
	}
	if got := status["connector_run_id"]; got != "run_v2_status" {
		t.Fatalf("connector_run_id = %#v, want run_v2_status", got)
	}
	if got := status["device_id"]; got != "dev_v2_status" {
		t.Fatalf("device_id = %#v, want dev_v2_status", got)
	}
}

func TestMetadataAdvertisesLocalFileIndexVersion(t *testing.T) {
	c, err := newConnector(config{
		name:               "local-file-reader",
		root:               t.TempDir(),
		localFileIndexRoot: t.TempDir(),
		systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	capabilities := c.metadata().Capabilities
	if got, present := capabilities["scope"]; !present || got != "" {
		t.Fatalf("full metadata scope = %#v present=%v, want explicit empty scope", got, present)
	}
	if got := capabilities["local_file_import_v1"]; got != true {
		t.Fatalf("local_file_import_v1 = %#v, want true", got)
	}
	if got := capabilities["local_file_index_version"]; got != 2 {
		t.Fatalf("local_file_index_version = %#v, want 2", got)
	}
}

func TestLocalFileReadScopeRefusesEveryMethodExceptReadRef(t *testing.T) {
	c, err := newConnector(config{
		name:                "attachment-reader",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "0123456789abcdef0123456789abcdef",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	refused := []string{
		"exec",
		"read",
		"write",
		"delete",
		"stat",
		"list",
		"glob",
		"grep",
		"computer_use",
		"read_stream",
		"write_stream",
		"process_start",
		"process_list",
		"process_write",
		"process_tail",
		"process_stop",
		"http_request",
		"agent_runtime_input",
		"runtime_probe",
		"meeting_join",
		"meeting_send_chat",
		"meeting_artifact_read",
	}
	for _, method := range refused {
		_, err := dispatchForTest(c, context.Background(), "req_scope", method, map[string]any{}, func(message) error {
			return nil
		})
		if err == nil || !strings.Contains(err.Error(), "not permitted") {
			t.Fatalf("method %q: error = %v, want scope refusal", method, err)
		}
	}

	// read_ref passes the scope gate and fails on its own parameter
	// validation instead of the scope refusal.
	_, err = dispatchForTest(c, context.Background(), "req_scope", "read_ref", map[string]any{}, func(message) error {
		return nil
	})
	if err == nil || strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("read_ref: error = %v, want a non-scope validation error", err)
	}
}

func TestScopedConnectorNeverProbesAgentRuntimes(t *testing.T) {
	c, err := newConnector(config{
		name:                "attachment-reader",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "33333333333333333333333333333333",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	probes := 0
	c.runtimeInventory.run = func(runtimeProbeTarget) map[string]any {
		probes++
		return map[string]any{}
	}

	var sent []message
	err = c.probeAndPublish(context.Background(), "connect", func(m message) error {
		sent = append(sent, m)
		return nil
	})
	if err != nil {
		t.Fatalf("probeAndPublish: %v", err)
	}
	// Probing can launch runtime processes (e.g. a Codex app-server); a
	// read_ref-only connector must publish its minimal metadata untouched.
	if probes != 0 {
		t.Fatalf("scoped connector probed %d runtime targets, want 0", probes)
	}
	if len(sent) != 1 || sent[0].Type != "metadata" {
		t.Fatalf("sent = %#v, want exactly one metadata frame", sent)
	}
	if got := sent[0].Capabilities["scope"]; got != scopeLocalFileRead {
		t.Fatalf("published scope = %#v, want %q", got, scopeLocalFileRead)
	}
}

func TestLocalFileReadScopeAdvertisesMinimalCapabilities(t *testing.T) {
	c, err := newConnector(config{
		name:                "attachment-reader",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "44444444444444444444444444444444",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	capabilities := c.metadata().Capabilities
	if got := capabilities["scope"]; got != scopeLocalFileRead {
		t.Fatalf("scope = %#v, want %q", got, scopeLocalFileRead)
	}
	if got := capabilities["local_file_import_v1"]; got != true {
		t.Fatalf("local_file_import_v1 = %#v, want true", got)
	}
	if got := capabilities["local_file_index_version"]; got != 2 {
		t.Fatalf("local_file_index_version = %#v, want 2", got)
	}
	for _, forbidden := range []string{
		"persistent_processes",
		"computer_use_tool",
		"runtime_probe",
		"meeting_runtime",
	} {
		if got := capabilities[forbidden]; got != false {
			t.Fatalf("%s = %#v, want false", forbidden, got)
		}
	}
	if _, present := capabilities["agent_runtimes"]; present {
		t.Fatalf("agent_runtimes must not be advertised by a scoped connector")
	}
	if got := capabilities["execution_boundary"]; got != "local-file-read-only" {
		t.Fatalf("execution_boundary = %#v, want local-file-read-only", got)
	}
}

func TestCommaDesktopScopeChangesInPlaceWithoutStartingExternalRuntimes(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "55555555555555555555555555555555",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	if got := c.currentScope(); got != scopeLocalFileRead {
		t.Fatalf("initial scope = %q, want %q", got, scopeLocalFileRead)
	}
	if err := c.setCurrentScope(""); err != nil {
		t.Fatalf("enable full scope: %v", err)
	}
	if got := c.currentScope(); got != "" {
		t.Fatalf("enabled scope = %q, want full", got)
	}
	if len(c.runtimeImplementations) != 0 {
		t.Fatalf("scope elevation must not initialize external runtimes")
	}

	capabilities := c.metadata().Capabilities
	if got := capabilities["persistent_processes"]; got != true {
		t.Fatalf("persistent_processes = %#v, want true", got)
	}
	if got := capabilities["runtime_probe"]; got != false {
		t.Fatalf("runtime_probe = %#v, want false", got)
	}
	if _, present := capabilities["agent_runtimes"]; present {
		t.Fatalf("dynamically elevated Comma connector must not advertise agent runtimes")
	}
	if _, err := dispatchForTest(c, context.Background(), "req_list", "process_list", map[string]any{}, func(message) error { return nil }); err != nil {
		t.Fatalf("full scope process_list: %v", err)
	}

	if err := c.setCurrentScope(scopeLocalFileRead); err != nil {
		t.Fatalf("restore restricted scope: %v", err)
	}
	if _, err := dispatchForTest(c, context.Background(), "req_blocked", "process_list", map[string]any{}, func(message) error { return nil }); err == nil || !strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("restricted process_list error = %v, want scope refusal", err)
	}
}

func TestScopeControlRequiresExactRunNonceAndPublishesMetadata(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "66666666666666666666666666666666",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	var sent []message
	session := c.claimConnection(context.Background(), func(_ context.Context, m message) error {
		sent = append(sent, m)
		return nil
	}, func(error) {})
	defer session.close(nil)

	commands := strings.NewReader(
		`{"type":"set_scope","run_nonce":"wrong","scope":""}` + "\n" +
			`{"type":"set_scope","run_nonce":"66666666666666666666666666666666"}` + "\n" +
			`{"type":"set_scope","run_nonce":"66666666666666666666666666666666","scope":""}` + "\n",
	)
	watchScopeControl(context.Background(), commands, c)

	if got := c.currentScope(); got != "" {
		t.Fatalf("scope = %q, want full after exact-nonce command", got)
	}
	if len(sent) != 1 || sent[0].Type != "metadata" {
		t.Fatalf("published = %#v, want one metadata replacement", sent)
	}
}

func TestScopeDowngradeFencesAnAlreadyAdmittedProcessStart(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "88888888888888888888888888888888",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}

	insideFence := make(chan struct{})
	releaseFence := make(chan struct{})
	c.beforeManagedProcessStart = func() {
		close(insideFence)
		<-releaseFence
	}
	marker := filepath.Join(t.TempDir(), "escaped")
	startDone := make(chan error, 1)
	go func() {
		_, err := dispatchForTest(c, context.Background(), "req_start_race", "process_start", map[string]any{
			"process_name": "race",
			"command":      "/bin/sh",
			"args":         []any{"-c", "touch " + shellQuote(marker)},
		}, func(message) error { return nil })
		startDone <- err
	}()
	<-insideFence

	downgradeDone := make(chan error, 1)
	go func() { downgradeDone <- c.setCurrentScope(scopeLocalFileRead) }()
	// The downgrade waits for processMu, which the admitted start holds inside
	// its fence.
	waitUntilParked(t, "sync.Mutex.Lock", "(*connector).stopManagedProcesses(")
	select {
	case err := <-downgradeDone:
		t.Fatalf("downgrade acknowledged before admitted process fence drained: %v", err)
	default:
	}
	close(releaseFence)
	if err := <-startDone; err == nil {
		t.Fatal("admitted process start unexpectedly succeeded across downgrade")
	}
	if err := <-downgradeDone; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("process escaped restricted transition (stat err = %v)", err)
	}
	c.processMu.Lock()
	defer c.processMu.Unlock()
	if process := c.processes["race"]; process != nil && process.isRunning() {
		t.Fatal("running process survived restricted acknowledgement")
	}
}

func TestScopeDowngradeAbortsPendingWriteStreamAndRejectsLaterFrames(t *testing.T) {
	root := t.TempDir()
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                root,
		runNonce:            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}

	terminal := make(chan message, 1)
	session := c.claimConnection(context.Background(), func(_ context.Context, frame message) error {
		if frame.ID == "write-after-downgrade" && frame.Type == "stream" {
			terminal <- frame
		}
		return nil
	}, func(error) {})
	defer session.close(nil)
	if _, err := c.dispatchSession(
		context.Background(),
		session,
		"write-after-downgrade",
		"write_stream",
		map[string]any{"path": "bounded.txt"},
	); err != nil {
		t.Fatalf("prepare write_stream: %v", err)
	}
	if session.pendingWrite("write-after-downgrade") == nil {
		t.Fatal("write_stream was not reserved")
	}

	if err := c.setCurrentScope(scopeLocalFileRead); err != nil {
		t.Fatal(err)
	}
	session.handleStream(message{
		ID:   "write-after-downgrade",
		Type: "stream",
		Stream: &streamData{
			Channel: "data",
			Data:    base64.StdEncoding.EncodeToString([]byte("must-not-land")),
			EOF:     true,
			Seq:     1,
		},
	})

	if session.pendingWrite("write-after-downgrade") != nil {
		t.Fatal("restricted transition retained pending write_stream")
	}
	frame := <-terminal
	if frame.Stream == nil || frame.Stream.Channel != "done" || !frame.Stream.EOF ||
		!strings.Contains(frame.Error, "scope restricted") {
		t.Fatalf("scope cancellation frame = %#v", frame)
	}
	content, err := os.ReadFile(filepath.Join(root, "bounded.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if len(content) != 0 {
		t.Fatalf("restricted stream frame altered file: %q", content)
	}
}

func TestScopeDowngradeDoesNotWaitForUserFileClose(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}

	session := c.claimConnection(context.Background(), func(context.Context, message) error {
		return nil
	}, func(error) {})
	defer session.close(nil)
	pending, err := session.reservePendingWrite("blocking-close")
	if err != nil {
		t.Fatal(err)
	}
	closer := &blockingCloseWriteCloser{blockingCloser: &blockingCloser{
		started: make(chan struct{}),
		release: make(chan struct{}),
	}}
	defer close(closer.release)
	if !session.activatePendingWrite("blocking-close", pending, closer) {
		t.Fatal("failed to activate pending write")
	}

	done := make(chan error, 1)
	go func() { done <- c.setCurrentScope(scopeLocalFileRead) }()
	err = <-done
	if err != nil {
		t.Fatal(err)
	}
	<-closer.started
}

func TestScopeStatusAcknowledgesOnlyAfterMetadataPublishAndPeriodicRetry(t *testing.T) {
	statusPath := filepath.Join(t.TempDir(), "connector.status.json")
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "99999999999999999999999999999999",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		statusPath:          statusPath,
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()
	c.writeStatus("connected", "", nil)

	session := c.claimConnection(context.Background(), func(context.Context, message) error {
		return errors.New("transport blocked")
	}, func(error) {})
	defer session.close(nil)
	watchScopeControl(context.Background(), strings.NewReader(
		`{"type":"set_scope","run_nonce":"99999999999999999999999999999999","scope":""}`+"\n",
	), c)

	raw, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	var status connectorStatusFile
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if status.Scope != scopeLocalFileRead {
		t.Fatalf("scope acknowledgement advanced after failed publish: %q", status.Scope)
	}

	// Unrelated request status must not acknowledge the unpublished scope.
	c.writeStatusLocalRequestError(errors.New("request failed while scope publish is pending"))
	raw, _ = os.ReadFile(statusPath)
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if status.Scope != scopeLocalFileRead {
		t.Fatalf("request error advanced unpublished scope acknowledgement: %q", status.Scope)
	}

	if err := c.publishPeriodicSystemInfo(func(message) error { return nil }); err != nil {
		t.Fatal(err)
	}
	c.writeStatusMetadataSent("")
	raw, _ = os.ReadFile(statusPath)
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if status.Scope != "" {
		t.Fatalf("periodic retry scope acknowledgement = %q, want full", status.Scope)
	}
}

func TestConnectURLCarriesCurrentScopeIncludingFull(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "77777777777777777777777777777777",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	restrictedURL, err := c.connectURL("https://salix.test")
	if err != nil {
		t.Fatal(err)
	}
	restricted, _ := url.Parse(restrictedURL)
	if got := restricted.Query().Get("scope"); got != scopeLocalFileRead {
		t.Fatalf("restricted query scope = %q", got)
	}

	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}
	fullURL, err := c.connectURL("https://salix.test")
	if err != nil {
		t.Fatal(err)
	}
	full, _ := url.Parse(fullURL)
	if values, present := full.Query()["scope"]; !present || len(values) != 1 || values[0] != "" {
		t.Fatalf("full query scope = %#v, want explicit empty value", values)
	}
}

func TestLocalFileReadScopeRequiresRunNonceAndParentLifeline(t *testing.T) {
	base := config{
		localFileIndexRoot: t.TempDir(),
		scope:              scopeLocalFileRead,
	}
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "run nonce") {
		t.Fatalf("missing run nonce: error = %v", err)
	}

	base.runNonce = "0123456789abcdef0123456789abcdef"
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "parent lifeline") {
		t.Fatalf("missing parent lifeline: error = %v", err)
	}

	base.parentLifelineFD = 3
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "shutdown request") {
		t.Fatalf("missing cooperative shutdown request: error = %v", err)
	}

	base.shutdownRequestPath = filepath.Join(t.TempDir(), "shutdown-request.json")
	if err := validateConfig(base); err != nil {
		t.Fatalf("complete containment identity rejected: %v", err)
	}

	base.parentLifelineFD = -1
	base.parentLifelinePipe = `\\.\pipe\comma-salix-parent-test`
	if err := validateConfig(base); err != nil {
		t.Fatalf("Windows named-pipe containment identity rejected: %v", err)
	}

	base.parentLifelineFD = 3
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("multiple parent lifelines: error = %v", err)
	}
}

func TestParentLifelineCancelsConnectorContextOnEOF(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	reads := make(chan struct{}, 4)
	go func() {
		watchParentLifeline(ctx, readSignalingReader{reader, reads}, cancel)
		close(done)
	}()

	<-reads
	if _, err := writer.Write([]byte("still-alive")); err != nil {
		t.Fatal(err)
	}
	// The watcher reads again only after it has handled the payload.
	select {
	case <-reads:
	case <-ctx.Done():
		t.Fatal("lifeline payload must not terminate the connector before EOF")
	}

	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	<-ctx.Done()
	<-done
}

// readSignalingReader sends on reads each time a Read starts.
type readSignalingReader struct {
	io.Reader
	reads chan<- struct{}
}

func (r readSignalingReader) Read(p []byte) (int, error) {
	r.reads <- struct{}{}
	return r.Reader.Read(p)
}

// The watcher polls on a ticker of the bubble's clock.
func TestCooperativeShutdownRequiresExactRunNonce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		requestPath := filepath.Join(t.TempDir(), "shutdown-request.json")
		runNonce := "0123456789abcdef0123456789abcdef"
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := make(chan struct{})
		go func() {
			watchShutdownRequest(ctx, requestPath, runNonce, cancel)
			close(done)
		}()

		wrong, err := json.Marshal(map[string]string{
			"runNonce": "ffffffffffffffffffffffffffffffff",
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(requestPath, wrong, 0o600); err != nil {
			t.Fatal(err)
		}
		// Three polls read the request for another run.
		time.Sleep(150 * time.Millisecond)
		synctest.Wait()
		select {
		case <-ctx.Done():
			t.Fatal("a shutdown request for another run must not cancel this connector")
		default:
		}

		exact, err := json.Marshal(map[string]string{"runNonce": runNonce})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(requestPath, exact, 0o600); err != nil {
			t.Fatal(err)
		}
		<-ctx.Done()
		<-done
	})
}

func TestMetadataIncludesSystemInfo(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()

	meta := c.metadata()
	if meta.Type != "metadata" {
		t.Fatalf("metadata type = %q, want metadata", meta.Type)
	}

	info := meta.SystemInfo
	if info == nil {
		t.Fatal("metadata is missing system_info")
	}

	for _, key := range []string{"hostname", "os_type", "arch", "cpu_count", "collected_at"} {
		if _, ok := info[key]; !ok {
			t.Errorf("system_info missing key %q (got %v)", key, info)
		}
	}

	if got := info["os_type"]; got != runtime.GOOS {
		t.Errorf("system_info os_type = %v, want %v", got, runtime.GOOS)
	}
	if got := info["arch"]; got != runtime.GOARCH {
		t.Errorf("system_info arch = %v, want %v", got, runtime.GOARCH)
	}
}

func TestMetadataReportsCodexAgentRuntime(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	codex := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_VERSION": "codex-cli 1.2.3",
	})
	t.Setenv("PATH", filepath.Dir(codex))

	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeRuntimes()
	if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
		t.Fatalf("initial runtime probe: %v", err)
	}
	before, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read probe log: %v", err)
	}

	meta := c.metadata()
	after, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read metadata log: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("metadata executed runtime probe: before=%q after=%q", before, after)
	}
	if got := meta.Capabilities["persistent_processes"]; got != true {
		t.Fatalf("persistent_processes = %v, want true", got)
	}

	runtimes, ok := meta.Capabilities["agent_runtimes"].([]map[string]any)
	if !ok {
		t.Fatalf("agent_runtimes type = %T, want []map[string]any", meta.Capabilities["agent_runtimes"])
	}
	if len(runtimes) != 1 {
		t.Fatalf("agent_runtimes len = %d, want 1: %#v", len(runtimes), runtimes)
	}

	rt := runtimes[0]
	if rt["kind"] != "external" {
		t.Fatalf("runtime kind = %v, want external", rt["kind"])
	}
	if rt["provider"] != "codex" {
		t.Fatalf("runtime provider = %v, want codex", rt["provider"])
	}
	if rt["status"] != "available" {
		t.Fatalf("runtime status = %v, want available: %#v", rt["status"], rt)
	}
	if rt["version"] != "codex-cli 1.2.3" {
		t.Fatalf("runtime version = %v", rt["version"])
	}
	if rt["version_detected"] != true {
		t.Fatalf("runtime version_detected = %v, want true", rt["version_detected"])
	}
	if rt["app_server_startable"] != true {
		t.Fatalf("runtime app_server_startable = %v, want true", rt["app_server_startable"])
	}
	if rt["auth_ready"] != true {
		t.Fatalf("runtime auth_ready = %v, want true", rt["auth_ready"])
	}
	if rt["ready"] != true {
		t.Fatalf("runtime ready = %v, want true", rt["ready"])
	}
	if rt["last_error"] != "" {
		t.Fatalf("runtime last_error = %v, want empty", rt["last_error"])
	}
	if _, ok := rt["readiness_checked_at"].(int64); !ok {
		t.Fatalf("runtime readiness_checked_at = %T, want int64", rt["readiness_checked_at"])
	}
	if _, ok := rt["readiness_valid_until"].(int64); !ok {
		t.Fatalf("runtime readiness_valid_until = %T, want int64", rt["readiness_valid_until"])
	}
	transports, ok := rt["transports"].([]string)
	if !ok || len(transports) != 1 || transports[0] != "ws" {
		t.Fatalf("runtime transports = %#v, want [ws]", rt["transports"])
	}
}

func TestRuntimeProbeCommandReportsReadyCodexRuntime(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	codex := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_VERSION": "codex-cli 2.0.0",
	})
	t.Setenv("PATH", filepath.Dir(codex))

	out, err := captureStdout(t, func() error {
		return runRuntimeProbeCommand([]string{"--json"})
	})
	if err != nil {
		t.Fatalf("runtime-probe: %v\n%s", err, out)
	}

	var report map[string]any
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("decode runtime-probe JSON: %v\n%s", err, out)
	}
	if report["ready"] != true || report["status"] != "available" {
		t.Fatalf("runtime-probe report = %#v", report)
	}
	runtimes, ok := report["agent_runtimes"].([]any)
	if !ok || len(runtimes) != 1 {
		t.Fatalf("agent_runtimes = %#v", report["agent_runtimes"])
	}
	runtime, ok := runtimes[0].(map[string]any)
	if !ok {
		t.Fatalf("runtime = %#v", runtimes[0])
	}
	if runtime["command"] != codex || runtime["version"] != "codex-cli 2.0.0" {
		t.Fatalf("runtime = %#v", runtime)
	}
	if runtime["auth_ready"] != true || runtime["app_server_startable"] != true {
		t.Fatalf("runtime readiness = %#v", runtime)
	}
}

func TestCodexReadinessRejectsConfiguredModelMissingFromNativeCatalog(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Mkdir(filepath.Join(home, ".codex"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".codex", "config.toml"), []byte("model = \"gpt-required\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "fake-codex.log"), map[string]string{
		"SALIX_TEST_FAKE_CODEX_MODELS": "gpt-other",
	})

	readiness := detectCodexReadiness(command)
	if readiness["ready"] != false || readiness["app_server_startable"] != false {
		t.Fatalf("readiness = %#v, want configured-model failure", readiness)
	}
	if !strings.Contains(stringFromAny(readiness["last_error"]), "configured model") {
		t.Fatalf("last_error = %#v, want configured-model diagnostic", readiness["last_error"])
	}
}

func TestCodexReadinessReportsAuthenticationMessageFromActualProbe(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", "")
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "fake-codex.log"), map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})

	readiness := detectCodexReadiness(command)
	if readiness["ready"] != false || readiness["auth_ready"] != false {
		t.Fatalf("readiness = %#v, want an unauthenticated runtime", readiness)
	}
	if readiness["readiness_issue"] != "authentication_required" {
		t.Fatalf("readiness_issue = %#v, want authentication_required", readiness["readiness_issue"])
	}
	if readiness["readiness_message"] != "Codex reports no authenticated account." {
		t.Fatalf("readiness_message = %#v", readiness["readiness_message"])
	}
}

func TestCodexReadinessMessagesDistinguishNativeFailureStages(t *testing.T) {
	for _, tc := range []struct{ failure, message string }{
		{"app-server start failed: permission denied", "The Codex native server could not be started."},
		{"app-server protocol probe failed: invalid response", "The Codex native server could not complete its readiness handshake."},
		{"app-server websocket probe timed out", "The Codex native server handshake timed out."},
	} {
		issue, message := codexReadinessDetail("", "", tc.failure)
		if issue != "native_server_unavailable" || message != tc.message {
			t.Fatalf("detail for %q = %q/%q", tc.failure, issue, message)
		}
	}
}

func TestCodexRuntimeRPCUsesWebSocket(t *testing.T) {
	received := make(chan map[string]any, 1)
	upgrader := websocket.Upgrader{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer ws.Close()

		var msg map[string]any
		if err := ws.ReadJSON(&msg); err != nil {
			t.Errorf("read app-server request: %v", err)
			return
		}
		received <- msg

		if err := ws.WriteJSON(map[string]any{
			"id":     msg["id"],
			"result": map[string]any{"ok": true},
		}); err != nil {
			t.Errorf("write app-server response: %v", err)
		}
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial fake app-server: %v", err)
	}

	rt := &codexRuntime{
		ws:      ws,
		done:    make(chan struct{}),
		nextID:  1,
		pending: map[string]chan map[string]any{},
	}
	defer rt.close()
	go rt.readLoop(ws)

	result, err := rt.rpc(
		context.Background(),
		"initialize",
		map[string]any{"hello": "world"},
		time.Second,
	)
	if err != nil {
		t.Fatalf("rpc: %v", err)
	}
	if result["ok"] != true {
		t.Fatalf("rpc result = %#v", result)
	}

	msg := receiveMap(t, received)
	if msg["method"] != "initialize" {
		t.Fatalf("method = %#v, want initialize", msg["method"])
	}
	if mapParam(msg, "params")["hello"] != "world" {
		t.Fatalf("params = %#v", msg["params"])
	}
}

func TestProcessMethodsSupportStdioLongRunningProcess(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	started, err := dispatchForTest(c, context.Background(), "req-start", "process_start", map[string]any{
		"process_name": "echoer",
		"command":      "/bin/sh",
		"args": []any{
			"-c",
			"while IFS= read -r line; do printf 'out:%s\\n' \"$line\"; done",
		},
	}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_start: %v", err)
	}
	if started.(map[string]any)["process_name"] != "echoer" {
		t.Fatalf("process_start result = %#v", started)
	}

	wrote, err := dispatchForTest(c, context.Background(), "req-write", "process_write", map[string]any{
		"process_name":   "echoer",
		"data":           "hello",
		"append_newline": true,
	}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_write: %v", err)
	}
	if wrote.(map[string]any)["bytes_written"].(int) == 0 {
		t.Fatalf("process_write wrote no bytes: %#v", wrote)
	}

	tailed, err := dispatchForTest(c, context.Background(), "req-tail", "process_tail", map[string]any{
		"process_name": "echoer",
		"from_offset":  0,
		"wait_seconds": 2,
		"max_bytes":    1024,
	}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_tail: %v", err)
	}

	tail := tailed.(map[string]any)
	if !strings.Contains(tail["data"].(string), "out:hello\n") {
		t.Fatalf("tail data = %#v", tail)
	}
	if tail["next_offset"].(int64) <= 0 {
		t.Fatalf("tail next_offset = %#v", tail["next_offset"])
	}

	listed, err := dispatchForTest(c, context.Background(), "req-list", "process_list", map[string]any{}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_list: %v", err)
	}
	if len(listed.(map[string]any)["processes"].([]map[string]any)) != 1 {
		t.Fatalf("process_list result = %#v", listed)
	}

	if _, err := dispatchForTest(c, context.Background(), "req-stop", "process_stop", map[string]any{
		"process_name": "echoer",
	}, func(message) error { return nil }); err != nil {
		t.Fatalf("process_stop: %v", err)
	}
}

func TestRunRemoteOnceSendsPeriodicSystemInfo(t *testing.T) {
	isolateHostRuntimeCommands(t)

	metas := make(chan message, 4)
	upgrader := websocket.Upgrader{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer ws.Close()

		for {
			var m message
			if err := ws.ReadJSON(&m); err != nil {
				return
			}
			if m.Type == "metadata" {
				select {
				case metas <- m:
				default:
				}
			}
		}
	}))
	defer server.Close()

	connector, err := newConnector(config{
		server:             server.URL,
		token:              "test-token",
		name:               "laptop",
		root:               t.TempDir(),
		systemInfoInterval: 50 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = connector.runRemoteOnce(ctx) }()

	// The first frame is the connect-time metadata; a second proves the timer
	// re-reports without any server prompting.
	first := receiveMessage(t, metas)
	if first.SystemInfo == nil {
		t.Fatalf("first metadata missing system_info")
	}

	second := receiveMessage(t, metas)
	if second.Type != "metadata" || second.SystemInfo == nil {
		t.Fatalf("expected periodic metadata with system_info, got %+v", second)
	}
}

func TestSystemInfoLoopRetriesAfterTransientPublishFailure(t *testing.T) {
	connector, err := newConnector(config{
		root:               t.TempDir(),
		systemInfoInterval: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer connector.closeRuntimes()

	done := make(chan struct{})
	defer close(done)
	var attempts atomic.Int32
	recovered := make(chan struct{}, 1)

	go connector.systemInfoLoopWithPublish(func() error {
		if attempts.Add(1) == 1 {
			return errors.New("transient publish failure")
		}
		select {
		case recovered <- struct{}{}:
		default:
		}
		return nil
	}, done, "")

	<-recovered
	if got := attempts.Load(); got < 2 {
		t.Fatalf("publish attempts = %d, want at least 2", got)
	}
}

func TestPeriodicSystemInfoPublishesCachedMetadataWithoutRuntimeProbe(t *testing.T) {
	connector, err := newConnector(config{root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer connector.closeRuntimes()
	connector.runtimeInventory.run = func(runtimeProbeTarget) map[string]any {
		t.Fatal("periodic system info must not run the runtime inventory probe")
		return nil
	}

	var got message
	if err := connector.publishPeriodicSystemInfo(func(m message) error {
		got = m
		return nil
	}); err != nil {
		t.Fatalf("publish periodic system info: %v", err)
	}
	if got.Type != "metadata" {
		t.Fatalf("message type = %q, want metadata", got.Type)
	}
	if got.SystemInfo == nil || got.SystemInfo["hostname"] == "" {
		t.Fatalf("system info = %#v, want host observation", got.SystemInfo)
	}
}

func receiveMessage(t *testing.T, messages <-chan message) message {
	t.Helper()

	msg := <-messages
	return msg
}

func assertCapability(t *testing.T, values map[string]any, key string, want any) {
	t.Helper()
	if got := values[key]; got != want {
		t.Fatalf("%s = %v, want %v in %v", key, got, want, values)
	}
}

func fakeCodexCommand(t *testing.T, logPath string, env map[string]string) string {
	t.Helper()
	// Readiness tests must not inherit the developer machine's real Codex
	// configuration or configured model.
	t.Setenv("CODEX_HOME", "")

	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("test executable: %v", err)
	}

	codex := filepath.Join(t.TempDir(), "codex")
	envLine := "SALIX_TEST_FAKE_CODEX=1 SALIX_TEST_FAKE_CODEX_LOG=" + shellQuote(logPath)
	for key, value := range env {
		envLine += " " + key + "=" + shellQuote(value)
	}
	script := "#!/bin/sh\n" + envLine + " exec " + shellQuote(exe) + " -test.run=TestHelperCodexAppServer -- \"$@\"\n"
	if err := os.WriteFile(codex, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake codex: %v", err)
	}
	return codex
}

func appendFakeProcessLog(path, line string) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintln(file, line)
	_ = file.Close()
}

func claimFakeCodexLoginStartResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_LOGIN_START_RESPONSE_ONCE")
	if path == "" {
		return false
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false
	}
	_ = file.Close()
	return true
}

func claimFakeCodexAccountReadFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_ACCOUNT_READ_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexLoginStartFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_LOGIN_START_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexLoginCancelResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_LOGIN_CANCEL_RESPONSE_ONCE")
	if path == "" {
		return false
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false
	}
	_ = file.Close()
	return true
}

func TestHelperCodexAppServer(t *testing.T) {
	if os.Getenv("SALIX_TEST_FAKE_CODEX") != "1" {
		return
	}
	args := helperProcessArgs()
	if len(args) == 1 && args[0] == "--version" {
		fmt.Println(defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_VERSION"), "codex fake"))
		os.Exit(0)
	}
	if len(args) == 2 && args[0] == "login" && args[1] == "status" {
		appendFakeCodexLog("login status")
		if marker := os.Getenv("SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS"); marker != "" {
			if _, err := os.Stat(marker); err == nil {
				fmt.Fprintln(os.Stderr, "Not logged in")
				os.Exit(1)
			}
		}
		if stderr := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_STDERR"); stderr != "" {
			fmt.Fprintln(os.Stderr, stderr)
		}
		if code := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_EXIT"); code != "" {
			exit, _ := strconv.Atoi(code)
			os.Exit(exit)
		}
		fmt.Println("Logged in using fake")
		os.Exit(0)
	}
	if len(args) != 5 || args[0] != "app-server" || args[1] != "--disable" ||
		args[2] != "tool_suggest" || args[3] != "--listen" {
		fmt.Fprintf(os.Stderr, "unexpected fake codex args: %#v\n", args)
		os.Exit(2)
	}
	if stderr := os.Getenv("SALIX_TEST_FAKE_CODEX_APP_SERVER_STDERR"); stderr != "" {
		fmt.Fprintln(os.Stderr, stderr)
	}
	if code := os.Getenv("SALIX_TEST_FAKE_CODEX_APP_SERVER_EXIT"); code != "" {
		exit, _ := strconv.Atoi(code)
		os.Exit(exit)
	}
	listen, err := url.Parse(args[4])
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse listen url: %v\n", err)
		os.Exit(2)
	}
	appendFakeCodexLog("start")
	waitForFakeMarker(os.Getenv("SALIX_TEST_FAKE_CODEX_READINESS_GATE"))
	if claimFakeCodexNormalExitBeforeListen() {
		os.Exit(0)
	}

	upgrader := websocket.Upgrader{}
	accountType := defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE"), "chatgpt")
	loginSeq := 0
	loginCanceled := map[string]bool{}
	var accountMu sync.Mutex
	server := &http.Server{
		Addr: listen.Host,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ws, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer ws.Close()
			initialized := false
			var writeMu sync.Mutex
			write := func(payload map[string]any) error {
				writeMu.Lock()
				defer writeMu.Unlock()
				return ws.WriteJSON(payload)
			}
			if gate := os.Getenv("SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_GATE"); gate != "" {
				go func() {
					waitForFakeMarker(gate)
					nextType := defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_TYPE"), "chatgpt")
					accountMu.Lock()
					accountType = nextType
					accountMu.Unlock()
					authMode := any("chatgpt")
					if nextType == "none" {
						authMode = nil
					}
					_ = write(map[string]any{
						"method": "account/updated",
						"params": map[string]any{"authMode": authMode},
					})
				}()
			}
			for {
				var msg map[string]any
				if err := ws.ReadJSON(&msg); err != nil {
					return
				}
				method := stringFromAny(msg["method"])
				appendFakeCodexLog(method)
				id := msg["id"]
				if id == "subscription-refresh-test" && method == "" {
					if stringParam(mapParam(msg, "result"), "accessToken") == "rotated-access" {
						appendFakeCodexLog("subscription-refresh-accepted")
					} else {
						appendFakeCodexLog("subscription-refresh-rejected")
					}
					continue
				}
				switch method {
				case "initialize":
					if claimFakeCodexInitializeConnectionClose() {
						return
					}
					if initialized {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32600,
								"message": "Already initialized",
							},
						})
						continue
					}
					if claimFakeCodexInitializeFailure() {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32603,
								"message": "transient initialize failure",
							},
						})
						continue
					}
					initialized = true
					if claimFakeCodexInitializeResponseDrop() {
						continue
					}
					result := map[string]any{"ok": true}
					if userAgent := os.Getenv("SALIX_TEST_FAKE_CODEX_USER_AGENT"); userAgent != "" {
						result["userAgent"] = userAgent
					}
					_ = write(map[string]any{"id": id, "result": result})
				case "config/read":
					_ = write(map[string]any{"id": id, "result": map[string]any{"config": map[string]any{"cli_auth_credentials_store": "file"}}})
				case "account/read":
					waitForFakeMarker(os.Getenv("SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE"))
					if claimFakeCodexAccountReadFailure() {
						_ = write(map[string]any{
							"id":    id,
							"error": map[string]any{"code": -32603, "message": "transient account read failure"},
						})
						continue
					}
					accountMu.Lock()
					currentAccountType := accountType
					accountMu.Unlock()
					if marker := os.Getenv("SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS"); marker != "" {
						if _, err := os.Stat(marker); err == nil {
							currentAccountType = "none"
						}
					}
					if marker := os.Getenv("SALIX_TEST_FAKE_CODEX_AUTH_SUCCESS_WHILE_EXISTS"); marker != "" {
						if _, err := os.Stat(marker); err == nil {
							currentAccountType = "chatgpt"
						}
					}
					_ = write(map[string]any{
						"id":     id,
						"result": fakeCodexAccountResult(currentAccountType),
					})
				case "account/login/start":
					params := mapParam(msg, "params")
					if stringParam(params, "type") == "chatgptAuthTokens" {
						if stringParam(params, "accessToken") == "" || stringParam(params, "chatgptAccountId") == "" {
							_ = write(map[string]any{"id": id, "error": map[string]any{"code": -32602, "message": "missing external auth material"}})
							continue
						}
						if stringParam(params, "accessToken") == "rotated-access" {
							appendFakeCodexLog("subscription-rotated-login")
						}
						accountMu.Lock()
						accountType = "chatgpt"
						accountMu.Unlock()
						_ = write(map[string]any{"id": id, "result": map[string]any{"type": "chatgptAuthTokens"}})
						continue
					}
					if stringParam(params, "type") != "chatgptDeviceCode" {
						_ = write(map[string]any{
							"id":    id,
							"error": map[string]any{"code": -32602, "message": "unsupported fake login flow"},
						})
						continue
					}
					if claimFakeCodexLoginStartFailure() {
						_ = write(map[string]any{
							"id":    id,
							"error": map[string]any{"code": -32603, "message": "transient login start failure"},
						})
						continue
					}
					accountMu.Lock()
					loginSeq++
					loginID := fmt.Sprintf("native-login-%d", loginSeq)
					loginCanceled[loginID] = false
					accountMu.Unlock()
					if claimFakeCodexLoginStartResponseDrop() {
						continue
					}
					responseLoginID := loginID
					if os.Getenv("SALIX_TEST_FAKE_CODEX_OMIT_LOGIN_ID") == "1" {
						responseLoginID = ""
					}
					_ = write(map[string]any{
						"id": id,
						"result": map[string]any{
							"type":            "chatgptDeviceCode",
							"loginId":         responseLoginID,
							"verificationUrl": defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_VERIFICATION_URL"), "https://auth.openai.com/codex/device"),
							"userCode":        defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_USER_CODE"), "ABCD-EFGH"),
						},
					})
					if os.Getenv("SALIX_TEST_FAKE_CODEX_EXIT_IMMEDIATELY_AFTER_LOGIN_START") == "1" {
						os.Exit(0)
					}
					if gate := os.Getenv("SALIX_TEST_FAKE_CODEX_EXIT_GATE_AFTER_LOGIN_START"); gate != "" {
						go func() {
							waitForFakeMarker(gate)
							os.Exit(0)
						}()
					}
					if gate := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE"); gate != "" {
						go func(nativeLoginID string) {
							waitForFakeMarker(gate)
							accountMu.Lock()
							canceled := loginCanceled[nativeLoginID]
							failure := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_OUTCOME") == "failure"
							if !canceled && !failure {
								accountType = "chatgpt"
							}
							accountMu.Unlock()
							if canceled {
								return
							}
							completionLoginID := defaultString(
								os.Getenv("SALIX_TEST_FAKE_CODEX_COMPLETION_LOGIN_ID"),
								nativeLoginID,
							)
							_ = write(map[string]any{
								"method": "account/login/completed",
								"params": map[string]any{
									"loginId": completionLoginID,
									"success": !failure,
									"error":   map[bool]any{true: "provider-secret-detail", false: nil}[failure],
								},
							})
							if !failure {
								_ = write(map[string]any{
									"method": "account/updated",
									"params": map[string]any{"authMode": "chatgpt"},
								})
							}
							appendFakeCodexLog("sent account/login/completed")
						}(loginID)
					}
				case "account/login/cancel":
					nativeLoginID := stringParam(mapParam(msg, "params"), "loginId")
					if claimFakeCodexLoginCancelResponseDrop() {
						continue
					}
					accountMu.Lock()
					_, found := loginCanceled[nativeLoginID]
					if found {
						loginCanceled[nativeLoginID] = true
					}
					accountMu.Unlock()
					status := "notFound"
					if found {
						status = "canceled"
					}
					_ = write(map[string]any{"id": id, "result": map[string]any{"status": status}})
				case "model/list":
					models := strings.Split(defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_MODELS"), "gpt-test"), ",")
					items := make([]map[string]any, 0, len(models))
					for _, model := range models {
						items = append(items, map[string]any{"id": model, "model": model})
					}
					_ = write(map[string]any{"id": id, "result": map[string]any{"data": items}})
				default:
					_ = write(map[string]any{"id": id, "result": map[string]any{"ok": true}})
				}
			}
		}),
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "fake codex server: %v\n", err)
		os.Exit(2)
	}
	os.Exit(0)
}

// waitForFakeMarker returns once the marker at path exists;
// waitForFakeMarkerRemoval once it no longer does. The tests that drive these
// fakes, in Go, Bun and Elixir, write and remove markers from another process,
// which a fake has no event for, so it polls. The wait has no deadline of its
// own.
func waitForFakeMarker(path string) { waitForFakeMarkerState(path, true) }

func waitForFakeMarkerState(path string, exists bool) {
	for path != "" {
		if _, err := os.Stat(path); (err == nil) == exists {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func fakeCodexAccountResult(accountType string) map[string]any {
	result := map[string]any{"requiresOpenaiAuth": true, "account": nil}
	switch accountType {
	case "none":
		return result
	case "notRequired":
		result["requiresOpenaiAuth"] = false
		return result
	case "chatgpt":
		result["account"] = map[string]any{
			"type": "chatgpt", "email": "private@example.test", "planType": "enterprise",
		}
	case "amazonBedrock":
		result["account"] = map[string]any{"type": "amazonBedrock", "credentialSource": "awsManaged"}
	default:
		result["account"] = map[string]any{"type": "apiKey"}
	}
	return result
}

func TestFakeRuntimeRepliesToEveryOutstandingMessageInBatch(t *testing.T) {
	batch, err := json.Marshal(map[string]any{
		"schema": "external_session_message_batch_v1",
		"messages": []any{
			map[string]any{"content": []any{map[string]any{"text": "Reply with COMMA31_REPLY_CONCURRENT_A."}}},
			map[string]any{"content": []any{map[string]any{"text": "Reply with COMMA31_REPLY_CONCURRENT_B. Then repeat COMMA31_REPLY_CONCURRENT_B."}}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := comma31ReplyText(fakeRuntimeInputText(string(batch)))
	if want := "COMMA31_REPLY_CONCURRENT_A\nCOMMA31_REPLY_CONCURRENT_B"; got != want {
		t.Fatalf("a settled fake turn must answer both outstanding messages: got %q, want %q", got, want)
	}
}

// A delivered batch can contain several outstanding messages (including an
// earlier message still awaiting a reply). The fake must answer all requested
// markers, not settle the whole batch after replying only to its first message.
func comma31ReplyText(text string) string {
	const prefix = "COMMA31_REPLY_"
	tokens := []string{}
	seen := map[string]bool{}
	for {
		start := strings.Index(text, prefix)
		if start < 0 {
			break
		}
		end := start + len(prefix)
		for end < len(text) {
			char := text[end]
			if (char < 'A' || char > 'Z') && (char < '0' || char > '9') && char != '_' {
				break
			}
			end++
		}
		token := text[start:end]
		if !seen[token] {
			tokens = append(tokens, token)
			seen[token] = true
		}
		text = text[end:]
	}
	return strings.Join(tokens, "\n")
}

func fakeRuntimeInputText(input string) string {
	var envelope struct {
		Schema   string `json:"schema"`
		Messages []struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		} `json:"messages"`
	}
	if json.Unmarshal([]byte(input), &envelope) != nil || envelope.Schema != "external_session_message_batch_v1" {
		return input
	}
	parts := []string{}
	for _, message := range envelope.Messages {
		for _, content := range message.Content {
			if content.Text != "" {
				parts = append(parts, content.Text)
			}
		}
	}
	return strings.Join(parts, "\n\n")
}

func helperProcessArgs() []string {
	for i, arg := range os.Args {
		if arg == "--" {
			return os.Args[i+1:]
		}
	}
	return nil
}

func appendFakeCodexLog(line string) {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_LOG")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line + "\n")
}

func claimFakeCodexNormalExitBeforeListen() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_LISTEN_ONCE")
	if path == "" || os.Remove(path) != nil {
		return false
	}
	_ = os.WriteFile(path+".bridge-url", []byte(os.Getenv("SALIX_CONNECT_URL")), 0o600)
	return true
}

func claimFakeCodexInitializeFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_INITIALIZE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexInitializeResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_INITIALIZE_RESPONSE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexInitializeConnectionClose() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_CLOSE_INITIALIZE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func receiveMap(t *testing.T, messages <-chan map[string]any) map[string]any {
	t.Helper()

	msg := <-messages
	return msg
}

func httpGetJSON(t *testing.T, endpoint string) map[string]any {
	t.Helper()
	resp, err := http.Get(endpoint)
	if err != nil {
		t.Fatalf("GET %s: %v", endpoint, err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode %s: %v", endpoint, err)
	}
	return body
}

func tarGzContains(t *testing.T, raw []byte, name string) bool {
	t.Helper()
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			return false
		}
		if err != nil {
			t.Fatalf("tar read: %v", err)
		}
		if header.Name == name {
			return true
		}
	}
}

type tarEntry struct {
	name string
	data []byte
}

func makeTarGz(t *testing.T, entries []tarEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, entry := range entries {
		if err := tw.WriteHeader(&tar.Header{
			Name: entry.name,
			Mode: 0o644,
			Size: int64(len(entry.data)),
		}); err != nil {
			t.Fatalf("write tar header: %v", err)
		}
		if _, err := tw.Write(entry.data); err != nil {
			t.Fatalf("write tar body: %v", err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}
	return buf.Bytes()
}

func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdout: %v", err)
	}
	os.Stdout = w
	defer func() {
		os.Stdout = oldStdout
		_ = r.Close()
	}()

	runErr := fn()
	_ = w.Close()
	raw, readErr := io.ReadAll(r)
	if readErr != nil {
		t.Fatalf("read stdout: %v", readErr)
	}
	return string(raw), runErr
}

func TestRetiredFlagsParseWithoutEffect(t *testing.T) {
	fs := flag.NewFlagSet("salix-connect", flag.ContinueOnError)
	var out bytes.Buffer
	fs.SetOutput(&out)
	root := fs.String("root", ".", "base directory for relative paths")
	registerRetiredFlags(fs)

	args := []string{"--root", "/tmp/workdir"}
	for _, name := range retiredFlags {
		args = append(args, "--"+name, "value")
	}
	for _, name := range retiredBoolFlags {
		args = append(args, "--"+name, "--"+name+"=false")
	}
	if err := fs.Parse(args); err != nil {
		t.Fatalf("parse retired flags: %v", err)
	}
	if *root != "/tmp/workdir" {
		t.Fatalf("root = %q", *root)
	}

	if fs.NArg() != 0 {
		t.Fatalf("retired flags left arguments: %q", fs.Args())
	}

	fs.Usage()
	for _, name := range append(append([]string{}, retiredFlags...), retiredBoolFlags...) {
		if strings.Contains(out.String(), "-"+name) {
			t.Fatalf("usage lists %q:\n%s", name, out.String())
		}
	}
	if !strings.Contains(out.String(), "-root") {
		t.Fatalf("usage omits -root:\n%s", out.String())
	}
}

func TestManagedArchivePreservesExecutableLinksAndNativeFiles(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "home/packages/cli/run")
	if err := os.MkdirAll(filepath.Dir(binary), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nprintf restored"), 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "home/packages/cli-command")
	if err := os.Symlink("cli/run", link); err != nil {
		t.Fatal(err)
	}
	history := filepath.Join(root, "home/native-history.json")
	if err := os.WriteFile(history, []byte(`{"session":"retained"}`), 0600); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	if err := writeTarGz(&archive, root); err != nil {
		t.Fatal(err)
	}
	restored := t.TempDir()
	if err := restoreTarGz(bytes.NewReader(archive.Bytes()), restored); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(filepath.Join(restored, "home/packages/cli-command")).Output()
	if err != nil || string(output) != "restored" {
		t.Fatalf("restored CLI: %s %v", output, err)
	}
	data, err := os.ReadFile(filepath.Join(restored, "home/native-history.json"))
	if err != nil || string(data) != `{"session":"retained"}` {
		t.Fatalf("history: %s %v", data, err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "external")); err != nil {
		t.Fatal(err)
	}
	if err := writeTarGz(io.Discard, root); err == nil {
		t.Fatal("archive must fail instead of omitting an external link")
	}
	if err := os.Remove(filepath.Join(root, "external")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "absent"), filepath.Join(root, "external")); err != nil {
		t.Fatal(err)
	}
	if err := writeTarGz(io.Discard, root); err == nil {
		t.Fatal("archive must reject an absent external link target")
	}
}

func TestArchiveKeepsGitMetadataAndUserFilesWhileSkippingGeneratedCaches(t *testing.T) {
	root := t.TempDir()
	workspace := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home/.comma/workspaces/session/repo")
	files := map[string]string{
		".git/refs/heads/local":     "unpushed commit",
		".gitignore":                "private.conf\n",
		"private.conf":              "user configuration",
		"node_modules/pkg/index.js": "locally patched dependency",
		"node_modules/notes.txt":    "user data",
		".venv/pyvenv.cfg":          "home = /usr/bin",
		".venv/notes.txt":           "user data",
		".venv/lib/python3.12/site-packages/pkg/source.py":            "patched installation",
		".venv/lib/python3.12/site-packages/pkg-1.dist-info/METADATA": "installation marker",
		".tox/env/user-notes.txt":                                     "user data",
		".nox/env/user-notes.txt":                                     "user data",
		".pixi/envs/default/user-notes.txt":                           "user data",
		"__pypackages__/3.12/lib/user-notes.txt":                      "user data",
		"package.json":                                                "{\"dependencies\":{\"pkg\":\"1.0.0\"}}",
		"package-lock.json":                                           "{\"lockfileVersion\":3}",
		"dist/output.js":                                              "generated build",
		".dart_tool/package_config.json":                              "generated package data",
		".cxx/object.o":                                               "generated native build",
		"xcuserdata/preferences":                                      "user settings",
		".swiftpm/configuration/mirrors.json":                         "user configuration",
		".terraform/terraform.tfstate":                                "backend metadata",
		".tools/local-tool":                                           "user tool",
	}
	for name, content := range files {
		path := filepath.Join(workspace, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	cache := filepath.Join(root, ".salix/sprite-home/.cache/go-build/object")
	if err := os.MkdirAll(filepath.Dir(cache), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache, []byte("generated"), 0600); err != nil {
		t.Fatal(err)
	}
	store := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home/.local/share/pnpm/store/v10/object")
	if err := os.MkdirAll(filepath.Dir(store), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store, []byte("generated"), 0600); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(root, "project/.comma/workspaces/session/repo/build/asset.txt")
	if err := os.MkdirAll(filepath.Dir(other), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, []byte("user-owned path"), 0600); err != nil {
		t.Fatal(err)
	}
	generatedHomeFiles := []string{
		".npm/_cacache/object", ".cargo/registry/src/crate/lib.rs",
		".gradle/caches/module.jar", ".android/cache/build.bin",
		".m2/repository/library.jar", ".hex/cache.ets",
		"Library/Developer/Xcode/DerivedData/App/Build/object.o",
		"go/pkg/mod/example/module.go",
	}
	for _, name := range generatedHomeFiles {
		path := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home", name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("generated"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	retainedHomeFiles := []string{
		".npmrc", ".cargo/config.toml", ".cargo/git/db/refs/heads/local",
		".gradle/gradle.properties", ".android/adbkey", ".m2/settings.xml",
		"Library/Developer/Xcode/Archives/App.xcarchive/Info.plist", "go/bin/tool",
	}
	for _, name := range retainedHomeFiles {
		path := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home", name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("retain"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	installation := ".salix/sprite-home/.local/share/sprite-agents/local-patch.js"
	if err := os.MkdirAll(filepath.Dir(filepath.Join(root, installation)), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, installation), []byte("user-patched tool"), 0600); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	if err := writeTarGz(&archive, root); err != nil {
		t.Fatal(err)
	}
	restored := t.TempDir()
	if err := restoreTarGz(bytes.NewReader(archive.Bytes()), restored); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(restored, installation)); err != nil || string(data) != "user-patched tool" {
		t.Fatalf("installed tool patch changed: %q, %v", data, err)
	}
	repo := filepath.Join(restored, ".salix/sprite-home/.local/share/salix/connector-home/.comma/workspaces/session/repo")
	for name := range files {
		if strings.HasPrefix(name, ".dart_tool/") || strings.HasPrefix(name, ".cxx/") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(repo, name))
		if err != nil || string(data) != files[name] {
			t.Fatalf("user file %s changed: %q, %v", name, data, err)
		}
	}
	for _, name := range []string{".dart_tool", ".cxx"} {
		if _, err := os.Stat(filepath.Join(repo, name)); !os.IsNotExist(err) {
			t.Fatalf("generated directory %s restored: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(restored, ".salix/sprite-home/.cache")); !os.IsNotExist(err) {
		t.Fatalf("runtime cache restored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(restored, ".salix/sprite-home/.local/share/salix/connector-home/.local/share/pnpm/store")); !os.IsNotExist(err) {
		t.Fatalf("dependency store restored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(restored, "project/.comma/workspaces/session/repo/build/asset.txt")); err != nil {
		t.Fatalf("unrelated project data missing: %v", err)
	}
	home := filepath.Join(restored, ".salix/sprite-home/.local/share/salix/connector-home")
	for _, name := range generatedHomeFiles {
		if _, err := os.Stat(filepath.Join(home, name)); !os.IsNotExist(err) {
			t.Fatalf("generated home cache %s restored: %v", name, err)
		}
	}
	for _, name := range retainedHomeFiles {
		if _, err := os.Stat(filepath.Join(home, name)); err != nil {
			t.Fatalf("home configuration %s missing: %v", name, err)
		}
	}
}

func TestArchiveExportsMoreThanOneHundredThousandEntries(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 100_001; i++ {
		if err := os.Mkdir(filepath.Join(root, fmt.Sprintf("entry-%06d", i)), 0700); err != nil {
			t.Fatal(err)
		}
	}
	var archive bytes.Buffer
	if err := writeTarGz(&archive, root); err != nil {
		t.Fatal(err)
	}
	gz, err := gzip.NewReader(bytes.NewReader(archive.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	count := 0
	for {
		_, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		count++
	}
	if count != 100_001 {
		t.Fatalf("archive entries = %d, want 100001", count)
	}
	restored := t.TempDir()
	if err := restoreTarGz(bytes.NewReader(archive.Bytes()), restored); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(restored, "entry-100000")); err != nil {
		t.Fatalf("last archive entry missing after restore: %v", err)
	}
}

func TestScopedConnectorsShareOneRootWithoutRuntimeState(t *testing.T) {
	root := t.TempDir()
	index := t.TempDir()

	first, err := newConnector(config{
		name:                "workspace-a",
		parentLifelineFD:    3,
		root:                root,
		runNonce:            "11111111111111111111111111111111",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  index,
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("first scoped connector: %v", err)
	}
	defer first.closeRuntimes()

	// An earlier implementation opened <root>/external-runtime/state.db with
	// an exclusive bolt lock, so a second scoped connector on the same root
	// failed with "open external runtime state: timeout".
	second, err := newConnector(config{
		name:                "workspace-b",
		parentLifelineFD:    3,
		root:                root,
		runNonce:            "22222222222222222222222222222222",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  index,
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("second scoped connector on the same root: %v", err)
	}
	defer second.closeRuntimes()

	if _, err := os.Stat(filepath.Join(root, "external-runtime", "state.db")); !os.IsNotExist(err) {
		t.Fatalf("scoped connectors must not create the external runtime database (stat err = %v)", err)
	}
	if len(first.runtimeImplementations) != 0 {
		t.Fatalf("scoped connector must not instantiate agent runtime implementations")
	}
}

func TestConnectorStartsBesideLegacyExternalRuntimeState(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	legacy := filepath.Join(root, legacyExternalRuntimeDir)
	if err := os.MkdirAll(filepath.Join(legacy, "active"), 0o700); err != nil {
		t.Fatal(err)
	}
	// Not a database: a legacy file is never opened, whatever it holds.
	if err := os.WriteFile(filepath.Join(legacy, "state.db"), []byte("legacy state"), 0o600); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		c, err := newConnector(config{root: root, systemInfoInterval: 0})
		if err != nil {
			t.Fatalf("connector beside legacy state: %v", err)
		}
		c.closeRuntimes()
	}
	if data, err := os.ReadFile(filepath.Join(legacy, "state.db")); err != nil || string(data) != "legacy state" {
		t.Fatalf("legacy state changed: %q, %v", data, err)
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

// newBareTestConnector is a connector without runtime implementations, for
// tests that install their own.
func newBareTestConnector(t *testing.T, root string) *connector {
	t.Helper()
	return &connector{root: root, runtimePending: map[string]runtimePendingRequest{}}
}
