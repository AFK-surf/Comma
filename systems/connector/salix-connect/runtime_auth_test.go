package main

import (
	"context"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestCodexReadinessUsesSafeAccountSnapshot(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	command := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})

	readiness := detectCodexReadiness(command)
	if readiness["auth_ready"] != false || readiness["app_server_startable"] != true || readiness["ready"] != false {
		t.Fatalf("readiness = %#v, want startable unauthenticated runtime", readiness)
	}
	auth := mapParam(readiness, "auth")
	if auth["schema_version"] != 1 || auth["status"] != "unauthenticated" || auth["requires_openai_auth"] != true {
		t.Fatalf("safe auth snapshot = %#v", auth)
	}
	encoded := fmt.Sprint(auth)
	for _, secret := range []string{"private@example.test", "enterprise", "loginId", "auth.json"} {
		if strings.Contains(encoded, secret) {
			t.Fatalf("safe auth snapshot leaked %q: %s", secret, encoded)
		}
	}
	logData, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(logData), "login status") {
		t.Fatalf("readiness invoked human-oriented codex login status: %s", logData)
	}
}

func TestRuntimeAuthAPIKeyRequiresProviderEvidence(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "apiKey"})
	observation := runtimeAuthTestObservation(c, command)
	if observation["ready"] != false || observation["auth_ready"] != false || mapParam(observation, "auth")["status"] != "configured" {
		t.Fatal("native API-key presence was treated as provider acceptance")
	}
	read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{"provider": "codex", "identity_material": command})
	if err != nil || mapParam(read, "auth")["status"] != "configured" {
		t.Fatal("read promoted unverified configuration")
	}
}

func TestRuntimeAuthDeviceCodeLifecycleReusesLongLivedCodex(t *testing.T) {
	completionGate := filepath.Join(t.TempDir(), "complete-login")
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE": completionGate,
	})
	if c.metadata().Capabilities["runtime_auth_v1"] != true {
		t.Fatal("eligible Codex inventory did not advertise capabilities.runtime_auth_v1")
	}

	startParams := map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}
	started, err := c.methodRuntimeAuthLoginStart(context.Background(), startParams)
	if err != nil {
		t.Fatalf("start login: %v", err)
	}
	if started["flow"] != "device_code" || started["reused"] != false ||
		started["verification_url"] != "https://auth.openai.com/codex/device" || started["user_code"] != "ABCD-EFGH" {
		t.Fatalf("start result = %#v", started)
	}
	attemptID := stringParam(started, "attempt_id")
	if attemptID == "" || int64Param(started, "expires_at", 0) <= 0 {
		t.Fatalf("start result has no bounded attempt = %#v", started)
	}
	if auth := mapParam(started, "auth"); auth["status"] != "pending" {
		t.Fatalf("start auth = %#v, want pending", auth)
	}

	reused, err := c.methodRuntimeAuthLoginStart(context.Background(), startParams)
	if err != nil {
		t.Fatalf("reuse login: %v", err)
	}
	if reused["attempt_id"] != attemptID || reused["reused"] != true || reused["user_code"] != started["user_code"] {
		t.Fatalf("reused start = %#v, first = %#v", reused, started)
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "browser",
	}); err == nil || !strings.Contains(err.Error(), "flow") {
		t.Fatalf("different flow error = %v, want conflict/unsupported flow", err)
	}

	// Auth operations do not monopolize ordinary Connector operations.
	if processes, err := c.methodProcessList(nil); err != nil || processes == nil {
		t.Fatalf("ordinary process_list while login pending = %#v, %v", processes, err)
	}
	if err := os.WriteFile(completionGate, []byte("complete\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "authenticated runtime metadata", func() bool {
		runtime := runtimeAuthTestObservation(c, command)
		return runtime["ready"] == true && mapParam(runtime, "auth")["status"] == "authenticated"
	})

	read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command,
	})
	if err != nil {
		t.Fatalf("read auth: %v", err)
	}
	if auth := mapParam(read, "auth"); auth["status"] != "authenticated" || auth["mode"] != "chatgpt" {
		t.Fatalf("authenticated read = %#v", read)
	}
	if _, ok := read["attempt_id"]; ok {
		t.Fatalf("terminal read retained attempt: %#v", read)
	}

	logData, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count("\n"+string(logData), "\nstart\n"); got != 1 {
		t.Fatalf("Codex app-server starts = %d, want one long-lived process; log:\n%s", got, logData)
	}
	if got := strings.Count(string(logData), "account/login/start\n"); got != 1 {
		t.Fatalf("native device-code starts = %d, want one; log:\n%s", got, logData)
	}
	if strings.Contains(string(logData), "account/login/cancel\n") {
		t.Fatalf("matching successful completion was canceled; log:\n%s", logData)
	}
}

func TestRuntimeAuthFullProbePreservesExactPendingAttempt(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	started, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	})
	if err != nil {
		t.Fatal(err)
	}

	probed, err := c.runtimeInventory.probe(
		context.Background(), "codex", command, "operator",
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(probed) != 1 || mapParam(probed[0], "auth")["status"] != "pending" {
		t.Fatalf("full probe erased active ceremony: %#v", probed)
	}
	if auth := mapParam(runtimeAuthTestObservation(c, command), "auth"); auth["status"] != "pending" {
		t.Fatalf("cached full probe erased active ceremony: %#v", auth)
	}
	attempt := c.runtimeAuthCoordinator().attempt(
		runtimeProbeTarget{provider: "codex", identityMaterial: command}.key(),
	)
	if attempt == nil || attempt.attemptID != started["attempt_id"] {
		t.Fatalf("full probe changed exact attempt: result=%#v attempt=%#v", started, attempt)
	}
}

func TestRuntimeAuthAuthenticationWaitsForFullReadinessBeforeAvailable(t *testing.T) {
	completionGate := filepath.Join(t.TempDir(), "complete-login")
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE": completionGate,
	})
	if err := os.MkdirAll(filepath.Dir(codexConfigPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(codexConfigPath(), []byte("model = \"missing-model\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}); err != nil {
		t.Fatal(err)
	}

	firstAuthenticated := make(chan map[string]any, 1)
	releasePublication := make(chan struct{})
	var releaseOnce sync.Once
	session := c.claimConnection(context.Background(), func(_ context.Context, frame message) error {
		runtimes, _ := frame.Capabilities["agent_runtimes"].([]map[string]any)
		for _, runtime := range runtimes {
			if stringParam(runtime, "provider") != "codex" ||
				stringParam(runtime, "identity_material") != command ||
				stringParam(mapParam(runtime, "auth"), "status") != "authenticated" {
				continue
			}
			select {
			case firstAuthenticated <- runtime:
				<-releasePublication
			default:
			}
		}
		return nil
	}, nil)
	t.Cleanup(func() {
		releaseOnce.Do(func() { close(releasePublication) })
		session.close(context.Canceled)
	})

	if err := os.WriteFile(completionGate, []byte("complete\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var first map[string]any
	first = <-firstAuthenticated
	if first["auth_ready"] != true || first["ready"] != false || first["status"] != "unavailable" {
		t.Fatalf("authentication bypassed full readiness probe: %#v", first)
	}
	releaseOnce.Do(func() { close(releasePublication) })
	waitForCondition(t, "model-unavailable full probe", func() bool {
		runtime := runtimeAuthTestObservation(c, command)
		return mapParam(runtime, "auth")["status"] == "authenticated" &&
			runtime["ready"] == false && runtime["readiness_issue"] == "model_unavailable"
	})
}

func TestRuntimeAuthGenerationRolloverInvalidatesInheritedFullReadiness(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "chatgpt",
	})
	initial := runtimeAuthTestObservation(c, command)
	if initial["ready"] != true || initial["status"] != "available" {
		t.Fatalf("G1 did not establish ready cache: %#v", initial)
	}
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	oldRuntime := implementation.runtimes[command]
	oldProof := oldRuntime != nil && oldRuntime.fullReadinessProven
	implementation.mu.Unlock()
	if oldRuntime == nil || !oldProof {
		t.Fatalf("G1 did not own its full-readiness proof: runtime=%#v proof=%v", oldRuntime, oldProof)
	}
	oldRuntime.terminate()
	<-oldRuntime.done
	if err := os.MkdirAll(filepath.Dir(codexConfigPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(codexConfigPath(), []byte("model = \"missing-model\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	firstG2Auth := make(chan map[string]any, 1)
	releasePublication := make(chan struct{})
	var releaseOnce sync.Once
	session := c.claimConnection(context.Background(), func(_ context.Context, frame message) error {
		runtimes, _ := frame.Capabilities["agent_runtimes"].([]map[string]any)
		for _, runtime := range runtimes {
			if stringParam(runtime, "provider") != "codex" ||
				stringParam(runtime, "identity_material") != command ||
				stringParam(mapParam(runtime, "auth"), "status") != "authenticated" {
				continue
			}
			select {
			case firstG2Auth <- runtime:
				<-releasePublication
			default:
			}
		}
		return nil
	}, nil)
	t.Cleanup(func() {
		releaseOnce.Do(func() { close(releasePublication) })
		session.close(context.Canceled)
	})

	type readOutcome struct {
		read map[string]any
		err  error
	}
	readDone := make(chan readOutcome, 1)
	go func() {
		read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command,
		})
		readDone <- readOutcome{read: read, err: err}
	}()

	var first map[string]any
	first = <-firstG2Auth
	if first["auth_ready"] != true || first["ready"] != false ||
		first["status"] != "unavailable" || first["readiness_issue"] != "runtime_probe_failed" {
		t.Fatalf("G2 inherited G1 full-readiness proof: %#v", first)
	}
	implementation.mu.Lock()
	newRuntime := implementation.runtimes[command]
	newProof := newRuntime != nil && newRuntime.fullReadinessProven
	implementation.mu.Unlock()
	if newRuntime == nil || newRuntime == oldRuntime || newProof {
		t.Fatalf("G2 readiness ownership before full probe: old=%#v new=%#v proof=%v", oldRuntime, newRuntime, newProof)
	}

	releaseOnce.Do(func() { close(releasePublication) })
	result := <-readDone
	if result.err != nil || mapParam(result.read, "auth")["status"] != "authenticated" {
		t.Fatalf("G2 runtime auth read = %#v, %v", result.read, result.err)
	}
	final := runtimeAuthTestObservation(c, command)
	if final["ready"] != false || final["status"] != "unavailable" ||
		final["readiness_issue"] != "model_unavailable" {
		t.Fatalf("G2 missing-model probe did not own final readiness: %#v", final)
	}
	implementation.mu.Lock()
	finalProof := newRuntime.fullReadinessProven
	implementation.mu.Unlock()
	if !finalProof {
		t.Fatal("G2 full probe did not establish exact-generation readiness ownership")
	}
}

func TestRuntimeAuthWebSocketDisconnectRetiresGenerationAndAttempt(t *testing.T) {
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	started, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	})
	if err != nil {
		t.Fatal(err)
	}
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	oldRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if oldRuntime == nil {
		t.Fatal("login did not retain its app-server generation")
	}
	oldRuntime.wsMu.Lock()
	oldWebSocket := oldRuntime.ws
	oldRuntime.wsMu.Unlock()
	if oldWebSocket == nil {
		t.Fatal("login app-server has no websocket")
	}
	if err := oldWebSocket.Close(); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "dead websocket generation retirement", func() bool {
		implementation.mu.Lock()
		defer implementation.mu.Unlock()
		return implementation.runtimes[command] != oldRuntime
	})
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	if attempt := c.runtimeAuthCoordinator().attempt(target.key()); attempt != nil {
		t.Fatalf("dead websocket retained its ceremony: %#v", attempt)
	}
	if auth := mapParam(runtimeAuthTestObservation(c, command), "auth"); auth["status"] != "error" || auth["issue"] != "login_failed" {
		t.Fatalf("dead websocket left pending metadata: %#v", auth)
	}

	restarted, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	})
	if err != nil {
		t.Fatalf("restart login after websocket loss: %v", err)
	}
	if restarted["reused"] != false || restarted["attempt_id"] == started["attempt_id"] {
		t.Fatalf("dead generation ceremony was reused: first=%#v restarted=%#v", started, restarted)
	}
	implementation.mu.Lock()
	newRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if newRuntime == nil || newRuntime == oldRuntime || newRuntime.generation == oldRuntime.generation {
		t.Fatalf("websocket loss did not create a fresh generation: old=%#v new=%#v", oldRuntime, newRuntime)
	}
	logData, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if got := strings.Count("\n"+string(logData), "\nstart\n"); got != 2 {
		t.Fatalf("app-server starts after websocket loss = %d, want 2; log:\n%s", got, logData)
	}
}

func TestRuntimeAuthUnusableFreshGenerationDoesNotDeadlockTargetLock(t *testing.T) {
	t.Run("connect timeout", func(t *testing.T) {
		readinessGate := filepath.Join(t.TempDir(), "app-server-ready")
		if err := os.WriteFile(readinessGate, []byte("ready\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":   "none",
			"SALIX_TEST_FAKE_CODEX_READINESS_GATE": readinessGate,
		})
		implementation := retireRuntimeAuthTestGeneration(t, c, command)
		if err := os.Remove(readinessGate); err != nil {
			t.Fatal(err)
		}
		implementation.mu.Lock()
		implementation.connectTimeout = 50 * time.Millisecond
		implementation.mu.Unlock()

		read := runtimeAuthReadWithoutTargetLockDeadlock(t, c, command)
		assertRuntimeAuthUnusableGenerationRetired(t, c, implementation, command, read)
	})

	t.Run("initialize connection close", func(t *testing.T) {
		closeInitialize := filepath.Join(t.TempDir(), "close-initialize")
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
			"SALIX_TEST_FAKE_CODEX_CLOSE_INITIALIZE_ONCE": closeInitialize,
		})
		implementation := retireRuntimeAuthTestGeneration(t, c, command)
		if err := os.WriteFile(closeInitialize, []byte("close\n"), 0o600); err != nil {
			t.Fatal(err)
		}

		read := runtimeAuthReadWithoutTargetLockDeadlock(t, c, command)
		assertRuntimeAuthUnusableGenerationRetired(t, c, implementation, command, read)
	})
}

func retireRuntimeAuthTestGeneration(
	t *testing.T,
	c *connector,
	command string,
) *codexRuntimeImplementation {
	t.Helper()
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if runtime == nil {
		t.Fatal("initial inventory did not retain a Codex app-server")
	}
	runtime.terminate()
	<-runtime.done
	return implementation
}

func runtimeAuthReadWithoutTargetLockDeadlock(
	t *testing.T,
	c *connector,
	command string,
) map[string]any {
	t.Helper()
	type outcome struct {
		read map[string]any
		err  error
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan outcome, 1)
	go func() {
		read, err := c.methodRuntimeAuthRead(ctx, map[string]any{
			"provider": "codex", "identity_material": command,
		})
		done <- outcome{read: read, err: err}
	}()

	// A read that deadlocks behind its own target lock never returns; the go
	// test timeout reports it.
	result := <-done
	if result.err != nil {
		t.Fatalf("runtime auth read: %v", result.err)
	}
	return result.read
}

func assertRuntimeAuthUnusableGenerationRetired(
	t *testing.T,
	c *connector,
	implementation *codexRuntimeImplementation,
	command string,
	read map[string]any,
) {
	t.Helper()
	auth := mapParam(read, "auth")
	if auth["status"] != "error" || auth["issue"] != "auth_probe_failed" {
		t.Fatalf("unusable generation read = %#v", read)
	}
	implementation.mu.Lock()
	current := implementation.runtimes[command]
	implementation.mu.Unlock()
	if current != nil {
		t.Fatalf("unusable generation remained current: %#v", current)
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	if attempt := c.runtimeAuthCoordinator().attempt(target.key()); attempt != nil {
		t.Fatalf("unusable uninitialized generation retained an auth attempt: %#v", attempt)
	}
	if cached := mapParam(runtimeAuthTestObservation(c, command), "auth"); cached["status"] != "error" || cached["issue"] != "auth_probe_failed" {
		t.Fatalf("unusable generation left stale cached auth: %#v", cached)
	}
}

func TestRuntimeAuthCapabilityRequiresEligibleCodexInventory(t *testing.T) {
	c, err := newConnector(config{name: "attachment-only", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeRuntimes)
	if _, exists := c.metadata().Capabilities["runtime_auth_v1"]; exists {
		t.Fatal("connector without an inventoried Codex runtime advertised runtime_auth_v1")
	}
}

func TestRuntimeAuthClosedImplementationRejectsProbeRestart(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.Close()
	if _, err := implementation.ensureTargetRuntime(context.Background(), runtimeProbeTarget{
		provider: "codex", identityMaterial: command,
	}); err == nil {
		t.Fatal("closed Codex implementation restarted an auth probe runtime")
	}
	implementation.mu.Lock()
	closed := implementation.closed
	runtimeCount := len(implementation.runtimes)
	implementation.mu.Unlock()
	if !closed || runtimeCount != 0 {
		t.Fatalf("closed implementation state: closed=%v runtimes=%d", closed, runtimeCount)
	}
}

func TestRuntimeAuthCancelFencesAttemptsAndClearsCeremony(t *testing.T) {
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	params := map[string]any{"provider": "codex", "identity_material": command, "flow": "device_code"}
	started, err := c.methodRuntimeAuthLoginStart(context.Background(), params)
	if err != nil {
		t.Fatal(err)
	}
	attemptID := stringParam(started, "attempt_id")

	if _, err := c.methodRuntimeAuthLoginCancel(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "attempt_id": "stale-attempt",
	}); err == nil || !strings.Contains(err.Error(), "attempt") {
		t.Fatalf("stale cancel error = %v", err)
	}
	canceled, err := c.methodRuntimeAuthLoginCancel(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "attempt_id": attemptID,
	})
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if canceled["canceled"] != true || canceled["attempt_id"] != attemptID || mapParam(canceled, "auth")["status"] != "unauthenticated" {
		t.Fatalf("cancel result = %#v", canceled)
	}
	for _, key := range []string{"verification_url", "user_code", "expires_at"} {
		if _, exists := canceled[key]; exists {
			t.Fatalf("cancel echoed ceremony field %q: %#v", key, canceled)
		}
	}
	read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := read["user_code"]; exists {
		t.Fatalf("read exposed ceremony: %#v", read)
	}
	logData, _ := os.ReadFile(logPath)
	if !strings.Contains(string(logData), "account/login/cancel") {
		t.Fatalf("native cancel not called: %s", logData)
	}
}

func TestRuntimeAuthCompletedStartReplyCannotResurrectTerminalCeremonyAfterReconnect(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	server := httptest.NewServer(c.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	startParams := map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}
	first := dialVMWebSocket(t, wsURL)
	if err := first.WriteJSON(message{
		ID: "stable-auth-start", Type: "request", Method: "runtime_auth_login_start", Params: startParams,
	}); err != nil {
		t.Fatal(err)
	}
	firstStart := readRuntimeAuthWebSocketReply(t, first, "stable-auth-start")
	firstResult, _ := firstStart.Result.(map[string]any)
	firstAttemptID := stringParam(firstResult, "attempt_id")
	if firstStart.Type != "response" || firstAttemptID == "" || stringParam(firstResult, "user_code") == "" {
		t.Fatalf("first start reply = %#v", firstStart)
	}

	if err := first.WriteJSON(message{
		ID: "cancel-first-auth", Type: "request", Method: "runtime_auth_login_cancel",
		Params: map[string]any{
			"provider": "codex", "identity_material": command, "attempt_id": firstAttemptID,
		},
	}); err != nil {
		t.Fatal(err)
	}
	canceled := readRuntimeAuthWebSocketReply(t, first, "cancel-first-auth")
	canceledResult, _ := canceled.Result.(map[string]any)
	if canceled.Type != "response" || canceledResult["canceled"] != true {
		t.Fatalf("cancel reply = %#v", canceled)
	}
	if attempt := c.runtimeAuthCoordinator().attempt(runtimeProbeTarget{
		provider: "codex", identityMaterial: command,
	}.key()); attempt != nil {
		t.Fatalf("terminal first ceremony remained active: %#v", attempt)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}

	replacement := dialVMWebSocket(t, wsURL)
	defer replacement.Close()
	if err := replacement.WriteJSON(message{
		ID: "stable-auth-start", Type: "request", Method: "runtime_auth_login_start", Params: startParams,
	}); err != nil {
		t.Fatal(err)
	}
	secondStart := readRuntimeAuthWebSocketReply(t, replacement, "stable-auth-start")
	secondResult, _ := secondStart.Result.(map[string]any)
	secondAttemptID := stringParam(secondResult, "attempt_id")
	if secondStart.Type != "response" || secondAttemptID == "" || secondAttemptID == firstAttemptID {
		t.Fatalf("replayed terminal ceremony instead of executing auth manager again: first=%#v second=%#v", firstStart, secondStart)
	}
	if secondResult["reused"] != false {
		t.Fatalf("replacement start did not create a fresh attempt: %#v", secondStart)
	}
}

// runtimeAuthTestEpoch is the time a test's own runtime auth clock starts at.
var runtimeAuthTestEpoch = time.Date(2026, time.January, 15, 12, 0, 0, 0, time.UTC)

// runtimeAuthTestObservedAt is the observation time of auth snapshots that
// tests publish themselves; publication orders snapshots by runtime generation
// and auth epoch, not by this time.
var runtimeAuthTestObservedAt = runtimeAuthTestEpoch.UnixMilli()

// runtimeAuthTestFarFuture is an attempt expiry that no test reaches.
var runtimeAuthTestFarFuture = testFarFuture.UnixMilli()

// waitForAttemptExpiry returns once the coordinator's clock has passed the
// expiry of the target's current login attempt.
func waitForAttemptExpiry(t *testing.T, coordinator *runtimeAuthCoordinator, target runtimeProbeTarget) {
	t.Helper()
	attempt := coordinator.attempt(target.key())
	if attempt == nil {
		t.Fatal("no login attempt to expire")
	}
	waitForCondition(t, "the login attempt to expire", func() bool {
		return attempt.expiresAt <= coordinator.now().UnixMilli()
	})
}

// readRuntimeAuthWebSocketReply reads frames until the reply to id. A reply
// that never comes stops the test at the go test timeout.
func readRuntimeAuthWebSocketReply(t *testing.T, ws *websocket.Conn, id string) message {
	t.Helper()
	for {
		var frame message
		if err := ws.ReadJSON(&frame); err != nil {
			t.Fatalf("read %s reply: %v", id, err)
		}
		if frame.ID == id {
			return frame
		}
		if frame.Type != "metadata" {
			t.Fatalf("unexpected frame while waiting for %s: %#v", id, frame)
		}
	}
}

func TestRuntimeAuthRejectsUnknownOrInjectedTargets(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	tests := []map[string]any{
		{"provider": "pi", "identity_material": command},
		{"provider": "codex", "identity_material": command + " --dangerous"},
		{"provider": "codex", "identity_material": command, "command": "/tmp/injected"},
		{"provider": "codex", "identity_material": command, "path": "/tmp/injected"},
	}
	for _, params := range tests {
		if _, err := c.methodRuntimeAuthRead(context.Background(), params); err == nil {
			t.Fatalf("runtime_auth_read accepted %#v", params)
		}
	}
}

func TestRuntimeAuthRejectsUnsafeCeremonyAndCancelsNativeAttempt(t *testing.T) {
	tests := map[string]string{
		"userinfo and insecure scheme": "http://operator:secret@auth.openai.com/codex/device",
		"attacker host":                "https://attacker.test/codex/device",
		"attacker path":                "https://auth.openai.com/not-codex/device",
		"query parameters":             "https://auth.openai.com/codex/device?continue=attacker",
	}
	for name, verificationURL := range tests {
		t.Run(name, func(t *testing.T) {
			c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
				"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":     "none",
				"SALIX_TEST_FAKE_CODEX_VERIFICATION_URL": verificationURL,
			})
			_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
				"provider": "codex", "identity_material": command, "flow": "device_code",
			})
			if err == nil || !strings.Contains(err.Error(), "invalid device-code ceremony") {
				t.Fatalf("unsafe ceremony error = %v", err)
			}
			logData, readErr := os.ReadFile(logPath)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if !strings.Contains(string(logData), "account/login/cancel\n") {
				t.Fatalf("invalid ceremony left native attempt active; log:\n%s", logData)
			}
		})
	}
}

func TestRuntimeAuthInvalidCeremonyWithoutLoginIDFencesGeneration(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":  "none",
		"SALIX_TEST_FAKE_CODEX_OMIT_LOGIN_ID": "1",
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	})
	if err == nil || !strings.Contains(err.Error(), "invalid device-code ceremony") {
		t.Fatalf("missing native login id error = %v", err)
	}
	implementation.mu.Lock()
	stillCurrent := implementation.runtimes[command] == runtime
	implementation.mu.Unlock()
	if stillCurrent {
		t.Fatal("uncancelable malformed native ceremony remained current")
	}
}

func TestRuntimeAuthFailureTimeoutAndRuntimeExitAreSafeTerminalStates(t *testing.T) {
	t.Run("provider failure", func(t *testing.T) {
		gate := filepath.Join(t.TempDir(), "fail-login")
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
			"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE": gate,
			"SALIX_TEST_FAKE_CODEX_LOGIN_OUTCOME":         "failure",
		})
		started, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(gate, []byte("fail\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		waitForCondition(t, "safe login failure", func() bool {
			auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
			return auth["status"] == "error" && auth["issue"] == "login_failed"
		})
		restarted, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		if err != nil {
			t.Fatal(err)
		}
		if restarted["attempt_id"] == started["attempt_id"] || restarted["reused"] != false {
			t.Fatalf("failed attempt was not cleared: first=%#v second=%#v", started, restarted)
		}
	})

	t.Run("timeout", func(t *testing.T) {
		c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
		})
		coordinator := c.runtimeAuthCoordinator()
		coordinator.ttl = time.Millisecond
		_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		if err != nil {
			t.Fatal(err)
		}
		waitForAttemptExpiry(t, coordinator, runtimeProbeTarget{provider: "codex", identityMaterial: command})
		read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command,
		})
		if err != nil {
			t.Fatal(err)
		}
		if auth := mapParam(read, "auth"); auth["status"] != "error" || auth["issue"] != "login_timeout" {
			t.Fatalf("expired read = %#v", read)
		}
		logData, _ := os.ReadFile(logPath)
		if !strings.Contains(string(logData), "account/login/cancel\n") {
			t.Fatalf("expired attempt was not canceled: %s", logData)
		}
	})

	t.Run("app server exit", func(t *testing.T) {
		exitGate := filepath.Join(t.TempDir(), "exit")
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                "none",
			"SALIX_TEST_FAKE_CODEX_EXIT_GATE_AFTER_LOGIN_START": exitGate,
		})
		_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		if err != nil {
			t.Fatal(err)
		}
		// The app-server exits once the login attempt is in place.
		if err := os.WriteFile(exitGate, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		waitForCondition(t, "runtime-exit auth failure", func() bool {
			auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
			return auth["status"] == "error" && auth["issue"] == "login_failed"
		})
	})

	t.Run("app server exit racing attempt installation", func(t *testing.T) {
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                       "none",
			"SALIX_TEST_FAKE_CODEX_EXIT_IMMEDIATELY_AFTER_LOGIN_START": "1",
		})
		target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
		_, _ = c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		waitForCondition(t, "exit-raced attempt cleanup", func() bool {
			return c.runtimeAuthCoordinator().attempt(target.key()) == nil
		})

		read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command,
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, exists := read["attempt_id"]; exists {
			t.Fatalf("read returned an attempt from the exited process: %#v", read)
		}
	})
}

func TestRuntimeAuthAmbiguousLoginStartResponseFencesProcessGeneration(t *testing.T) {
	dropMarker := filepath.Join(t.TempDir(), "drop-login-start-response-once")
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                   "none",
		"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_START_RESPONSE_ONCE": dropMarker,
	})
	manager := c.runtimeAuthCoordinator()
	manager.startTimeout = 50 * time.Millisecond
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	firstRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if firstRuntime == nil {
		t.Fatal("initial inventory did not retain a Codex app-server")
	}
	params := map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), params); err == nil ||
		!strings.Contains(err.Error(), "login failed") {
		t.Fatalf("dropped account/login/start response error = %v", err)
	}
	if manager.attempt(runtimeProbeTarget{provider: "codex", identityMaterial: command}.key()) != nil {
		t.Fatal("ambiguous start installed a reusable Connector attempt")
	}
	implementation.mu.Lock()
	stillCurrent := implementation.runtimes[command] == firstRuntime
	implementation.mu.Unlock()
	if stillCurrent {
		t.Fatal("ambiguous start left its app-server generation eligible for retry")
	}

	started, err := c.methodRuntimeAuthLoginStart(context.Background(), params)
	if err != nil {
		t.Fatalf("retry on fresh app-server generation: %v", err)
	}
	attempt := manager.attempt(runtimeProbeTarget{provider: "codex", identityMaterial: command}.key())
	if attempt == nil || attempt.runtime == firstRuntime || attempt.runtimeGeneration == firstRuntime.generation {
		t.Fatalf("retry attempt did not move to a fresh generation: %#v", attempt)
	}
	if started["reused"] != false || started["attempt_id"] != attempt.attemptID {
		t.Fatalf("fresh start result = %#v, attempt = %#v", started, attempt)
	}
	logData, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count("\n"+string(logData), "\nstart\n"); got != 2 {
		t.Fatalf("app-server generations = %d, want 2; log:\n%s", got, logData)
	}
	if got := strings.Count(string(logData), "account/login/start\n"); got != 2 {
		t.Fatalf("native starts = %d, want one ambiguous plus one current; log:\n%s", got, logData)
	}
}

func TestRuntimeAuthExplicitLoginStartErrorKeepsCurrentGeneration(t *testing.T) {
	failMarker := filepath.Join(t.TempDir(), "fail-login-start-once")
	if err := os.WriteFile(failMarker, []byte("fail\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
		"SALIX_TEST_FAKE_CODEX_FAIL_LOGIN_START_ONCE": failMarker,
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	params := map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), params); err == nil ||
		!strings.Contains(err.Error(), "login failed") {
		t.Fatalf("explicit account/login/start RPC error = %v", err)
	}
	implementation.mu.Lock()
	current := implementation.runtimes[command]
	implementation.mu.Unlock()
	if current != runtime || runtime == nil || !runtime.isRunning() {
		t.Fatalf("explicit start rejection fenced usable runtime: old=%#v current=%#v", runtime, current)
	}
	started, err := c.methodRuntimeAuthLoginStart(context.Background(), params)
	if err != nil {
		t.Fatalf("retry after explicit start rejection: %v", err)
	}
	if attempt := c.runtimeAuthCoordinator().attempt(runtimeProbeTarget{
		provider: "codex", identityMaterial: command,
	}.key()); attempt == nil || attempt.runtime != runtime || attempt.attemptID != started["attempt_id"] {
		t.Fatalf("retry did not retain exact usable runtime: result=%#v attempt=%#v", started, attempt)
	}
	logData, _ := os.ReadFile(logPath)
	if got := strings.Count("\n"+string(logData), "\nstart\n"); got != 1 {
		t.Fatalf("explicit RPC rejection restarted app-server %d times; log:\n%s", got, logData)
	}
}

func TestRuntimeAuthStartRetiresCeremonyWhenPendingPublicationLosesTarget(t *testing.T) {
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	manager := c.runtimeAuthCoordinator()
	manager.beforePendingPublication = func() {
		c.runtimeInventory.mu.Lock()
		delete(c.runtimeInventory.runtimes, target.key())
		c.runtimeInventory.mu.Unlock()
	}
	_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	})
	if err == nil || !strings.Contains(err.Error(), "target changed") {
		t.Fatalf("lost pending publication error = %v", err)
	}
	if attempt := manager.attempt(target.key()); attempt != nil {
		t.Fatalf("lost pending publication retained ceremony: %#v", attempt)
	}
	logData, _ := os.ReadFile(logPath)
	if !strings.Contains(string(logData), "account/login/cancel\n") {
		t.Fatalf("lost pending publication did not retire native ceremony; log:\n%s", logData)
	}
}

func TestRuntimeAuthCompletionAfterConnectorExpiryCannotWin(t *testing.T) {
	completionGate := filepath.Join(t.TempDir(), "late-completion")
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE": completionGate,
	})
	manager := c.runtimeAuthCoordinator()
	manager.ttl = 20 * time.Millisecond
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}); err != nil {
		t.Fatal(err)
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	waitForAttemptExpiry(t, manager, target)
	if err := os.WriteFile(completionGate, []byte("complete\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "late completion timeout fence", func() bool {
		auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
		return auth["status"] == "error" && auth["issue"] == "login_timeout" &&
			manager.attempt(target.key()) == nil
	})
	// The expiry fence terminated the generation; once it has exited it can
	// deliver nothing more. A generation left running never exits, and the go
	// test timeout reports it.
	<-runtime.done
	auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
	if auth["status"] != "error" || auth["issue"] != "login_timeout" {
		t.Fatalf("late completion published authenticated state: %#v", auth)
	}
	logData, _ := os.ReadFile(logPath)
	if !strings.Contains(string(logData), "account/login/cancel\n") {
		t.Fatalf("expired native attempt was not canceled; log:\n%s", logData)
	}
}

func TestRuntimeAuthNotificationsCoalesceAndKeepForegroundReadHealthy(t *testing.T) {
	readGate := filepath.Join(t.TempDir(), "account-read-gate")
	if err := os.WriteFile(readGate, []byte("open\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":      "none",
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE": readGate,
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if runtime == nil {
		t.Fatal("initial inventory did not retain a Codex app-server")
	}
	baselineLog, _ := os.ReadFile(logPath)
	baselineReads := strings.Count(string(baselineLog), "account/read\n")
	if err := os.Remove(readGate); err != nil {
		t.Fatal(err)
	}
	manager := c.runtimeAuthCoordinator()
	notification := map[string]any{
		"method": "account/updated", "params": map[string]any{"authMode": nil},
	}
	manager.handleNotification(runtime, notification)
	waitForCondition(t, "blocked notification account/read", func() bool {
		logData, _ := os.ReadFile(logPath)
		return strings.Count(string(logData), "account/read\n") > baselineReads
	})
	for range 10_000 {
		manager.handleNotification(runtime, notification)
	}
	manager.mu.Lock()
	stateCount := len(manager.notifications)
	state := manager.notifications[runtimeProbeTarget{provider: "codex", identityMaterial: command}.key()]
	manager.mu.Unlock()
	if stateCount != 1 || state == nil || !state.running {
		t.Fatalf("coalesced notification state count=%d state=%#v", stateCount, state)
	}

	readDone := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		_, err := c.methodRuntimeAuthRead(ctx, map[string]any{
			"provider": "codex", "identity_material": command,
		})
		readDone <- err
	}()
	if err := os.WriteFile(readGate, []byte("open\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := <-readDone
	if err != nil {
		t.Fatalf("foreground read after notification flood: %v", err)
	}
	waitForCondition(t, "notification worker drain", func() bool {
		manager.mu.Lock()
		defer manager.mu.Unlock()
		return len(manager.notifications) == 0
	})
	logData, _ := os.ReadFile(logPath)
	reads := strings.Count(string(logData), "account/read\n") - baselineReads
	if reads > 8 {
		t.Fatalf("10,000 duplicate notifications produced %d account reads; log:\n%s", reads, logData)
	}
}

func TestRuntimeAuthGenerationConditionalPublicationRejectsStaleRuntime(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	oldRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if oldRuntime == nil {
		t.Fatal("initial inventory did not retain a Codex app-server")
	}
	implementation.fenceRuntimeGeneration(oldRuntime)
	if _, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command,
	}); err != nil {
		t.Fatal(err)
	}
	implementation.mu.Lock()
	newRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if newRuntime == nil || newRuntime == oldRuntime {
		t.Fatalf("replacement runtime = %#v, old = %#v", newRuntime, oldRuntime)
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	if c.runtimeAuthCoordinator().publishSnapshotForRuntime(
		target,
		oldRuntime,
		codexAuthIssueSnapshot("auth_probe_failed", runtimeAuthTestObservedAt),
	) {
		t.Fatal("stale G1 auth snapshot was accepted after G2 became current")
	}
	committed := false
	if implementation.commitRuntimeProbe(target, oldRuntime.generation, oldRuntime.authEpoch, nil, func() { committed = true }) || committed {
		t.Fatal("stale G1 full probe was committed after G2 became current")
	}
	auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
	if auth["status"] != "unauthenticated" {
		t.Fatalf("stale G1 publication overwrote G2 metadata: %#v", auth)
	}
}

func TestRuntimeAuthEpochRejectsOlderProbeFromSameGeneration(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	staleEpoch := runtime.authEpoch
	implementation.mu.Unlock()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	newer := codexPendingAuthSnapshot(runtimeAuthTestObservedAt)
	if !c.runtimeAuthCoordinator().publishSnapshotForRuntime(target, runtime, newer) {
		t.Fatal("failed to publish newer same-generation auth observation")
	}
	committed := false
	accepted := implementation.commitRuntimeProbe(
		target,
		runtime.generation,
		staleEpoch,
		nil,
		func() {
			committed = true
			c.runtimeInventory.updateAuthSnapshot(
				target,
				codexAuthIssueSnapshot("auth_probe_failed", runtimeAuthTestObservedAt),
				false,
			)
		},
	)
	if accepted || committed {
		t.Fatal("older same-generation probe overwrote a newer auth publication")
	}
	auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
	if auth["status"] != "pending" {
		t.Fatalf("older same-generation probe won: %#v", auth)
	}
}

func TestRuntimeAuthInflightProbeRetriesAfterIncrementalEpochPublication(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	originalRun := c.runtimeInventory.run
	firstReady, firstRelease := make(chan struct{}), make(chan struct{})
	secondReady, secondRelease := make(chan struct{}), make(chan struct{})
	var runs atomic.Int32
	c.runtimeInventory.run = func(target runtimeProbeTarget) map[string]any {
		observation := originalRun(target)
		switch runs.Add(1) {
		case 1:
			close(firstReady)
			<-firstRelease
		case 2:
			close(secondReady)
			<-secondRelease
		}
		return observation
	}

	type probeResult struct {
		runtimes []map[string]any
		err      error
	}
	result := make(chan probeResult, 1)
	go func() {
		runtimes, err := c.runtimeInventory.probe(
			context.Background(), target.provider, target.identityMaterial, "operator",
		)
		result <- probeResult{runtimes: runtimes, err: err}
	}()
	<-firstReady
	newer := codexPendingAuthSnapshot(runtimeAuthTestObservedAt)
	if !c.runtimeAuthCoordinator().publishSnapshotForRuntime(target, runtime, newer) {
		t.Fatal("failed to publish incremental same-generation auth observation")
	}
	close(firstRelease)
	<-secondReady
	if auth := mapParam(runtimeAuthTestObservation(c, command), "auth"); auth["status"] != "pending" {
		t.Fatalf("stale in-flight probe overwrote incremental auth state before retry: %#v", auth)
	}
	close(secondRelease)
	completed := <-result
	if completed.err != nil || len(completed.runtimes) != 1 ||
		mapParam(completed.runtimes[0], "auth")["status"] != "unauthenticated" {
		t.Fatalf("retried in-flight probe = %#v, %v", completed.runtimes, completed.err)
	}
	if runs.Load() != 2 {
		t.Fatalf("in-flight epoch race runs = %d, want stale observation plus one retry", runs.Load())
	}
}

func TestRuntimeProbeCommitsFailureFromExactCurrentGeneration(t *testing.T) {
	failMarker := filepath.Join(t.TempDir(), "fail-account-read-once")
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":           "none",
		"SALIX_TEST_FAKE_CODEX_FAIL_ACCOUNT_READ_ONCE": failMarker,
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if runtime == nil {
		t.Fatal("initial inventory did not retain a Codex app-server")
	}
	if err := os.WriteFile(failMarker, []byte("fail\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimes, err := c.runtimeInventory.probe(
		context.Background(),
		"codex",
		command,
		"operator",
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(runtimes) != 1 || mapParam(runtimes[0], "auth")["issue"] != "auth_probe_failed" ||
		runtimes[0]["readiness_issue"] != "native_server_unavailable" {
		t.Fatalf("current-generation account/read failure was not committed: %#v", runtimes)
	}
	implementation.mu.Lock()
	current := implementation.runtimes[command]
	implementation.mu.Unlock()
	if current != runtime || !current.isRunning() {
		t.Fatalf("account/read failure unexpectedly replaced current runtime: old=%#v current=%#v", runtime, current)
	}
	cached := runtimeAuthTestObservation(c, command)
	if mapParam(cached, "auth")["issue"] != "auth_probe_failed" {
		t.Fatalf("cached current-generation failure = %#v", cached)
	}
}

func TestRuntimeProbeCommitsExplicitInitializeFailureFromExactCurrentGeneration(t *testing.T) {
	failMarker := filepath.Join(t.TempDir(), "fail-initialize-once")
	if err := os.WriteFile(failMarker, []byte("fail\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":         "none",
		"SALIX_TEST_FAKE_CODEX_FAIL_INITIALIZE_ONCE": failMarker,
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if runtime == nil || !runtime.isRunning() {
		t.Fatalf("explicit initialize rejection did not retain exact runtime generation: %#v", runtime)
	}
	cached := runtimeAuthTestObservation(c, command)
	if mapParam(cached, "auth")["issue"] != "auth_probe_failed" ||
		cached["readiness_issue"] != "native_server_unavailable" {
		t.Fatalf("current-generation initialize failure was not committed: %#v", cached)
	}

	runtimes, err := c.runtimeInventory.probe(
		context.Background(),
		"codex",
		command,
		"operator",
	)
	if err != nil {
		t.Fatal(err)
	}
	implementation.mu.Lock()
	current := implementation.runtimes[command]
	implementation.mu.Unlock()
	if current != runtime {
		t.Fatalf("explicit initialize retry replaced a usable generation: old=%#v current=%#v", runtime, current)
	}
	if len(runtimes) != 1 || mapParam(runtimes[0], "auth")["status"] != "unauthenticated" {
		t.Fatalf("initialize retry did not recover exact generation: %#v", runtimes)
	}
}

func TestRuntimeAuthReadRemovesAttemptFromStaleRuntimeGeneration(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	oldRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if oldRuntime == nil {
		t.Fatal("initial inventory did not retain its Codex app-server")
	}
	stopCtx, cancelStop := context.WithCancel(context.Background())
	if err := stopNativeProcess(stopCtx, oldRuntime.terminate, oldRuntime.done); err != nil {
		cancelStop()
		t.Fatalf("stop old Codex app-server: %v", err)
	}
	cancelStop()

	if _, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command,
	}); err != nil {
		t.Fatalf("start replacement Codex app-server: %v", err)
	}
	implementation.mu.Lock()
	newRuntime := implementation.runtimes[command]
	implementation.mu.Unlock()
	if newRuntime == nil || newRuntime == oldRuntime || newRuntime.generation == oldRuntime.generation {
		t.Fatalf("replacement runtime = %#v, old = %#v", newRuntime, oldRuntime)
	}

	stale := &runtimeAuthAttempt{
		attemptID:         "stale-attempt",
		flow:              runtimeAuthFlowDeviceCode,
		nativeLoginID:     "stale-native-login",
		verificationURL:   "https://auth.openai.com/codex/device",
		userCode:          "STALE-CODE",
		expiresAt:         runtimeAuthTestFarFuture,
		runtime:           oldRuntime,
		runtimeGeneration: oldRuntime.generation,
	}
	manager := c.runtimeAuthCoordinator()
	manager.mu.Lock()
	manager.attempts[target.key()] = stale
	manager.mu.Unlock()

	read, err := c.methodRuntimeAuthRead(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := read["attempt_id"]; exists {
		t.Fatalf("read returned a stale-generation attempt: %#v", read)
	}
	if remaining := manager.attempt(target.key()); remaining != nil {
		t.Fatalf("read retained stale-generation attempt: %#v", remaining)
	}
}

func TestRuntimeAuthCancelsAttemptWhenAccountAuthenticatesWithoutMatchingCompletion(t *testing.T) {
	gate := filepath.Join(t.TempDir(), "stale-completion")
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE": gate,
		"SALIX_TEST_FAKE_CODEX_COMPLETION_LOGIN_ID":   "stale-native-login",
	})
	params := map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}
	_, err := c.methodRuntimeAuthLoginStart(context.Background(), params)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(gate, []byte("complete\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "superseded native attempt cancellation", func() bool {
		logData, _ := os.ReadFile(logPath)
		return mapParam(runtimeAuthTestObservation(c, command), "auth")["status"] == "authenticated" &&
			c.runtimeAuthCoordinator().attempt(runtimeProbeTarget{
				provider: "codex", identityMaterial: command,
			}.key()) == nil && strings.Contains(string(logData), "account/login/cancel\n")
	})
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), params); err == nil ||
		!strings.Contains(err.Error(), "already authenticated") {
		t.Fatalf("new login after external authentication error = %v", err)
	}
}

func TestRuntimeAuthTracksExternalAccountUpdatesWithoutActiveAttempt(t *testing.T) {
	t.Run("signed out to signed in", func(t *testing.T) {
		gate := filepath.Join(t.TempDir(), "external-sign-in")
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
			"SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_GATE": gate,
			"SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_TYPE": "chatgpt",
		})
		if runtime := runtimeAuthTestObservation(c, command); runtime["ready"] != false || mapParam(runtime, "auth")["status"] != "unauthenticated" {
			t.Fatalf("initial signed-out runtime = %#v", runtime)
		}
		if err := os.WriteFile(gate, []byte("sign-in\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		waitForCondition(t, "external sign-in", func() bool {
			runtime := runtimeAuthTestObservation(c, command)
			return runtime["ready"] == true && runtime["status"] == "available" &&
				mapParam(runtime, "auth")["status"] == "authenticated"
		})
	})

	t.Run("signed in to signed out", func(t *testing.T) {
		gate := filepath.Join(t.TempDir(), "external-sign-out")
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "chatgpt",
			"SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_GATE": gate,
			"SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_TYPE": "none",
		})
		if runtime := runtimeAuthTestObservation(c, command); runtime["ready"] != true {
			t.Fatalf("initial signed-in runtime = %#v", runtime)
		}
		if err := os.WriteFile(gate, []byte("sign-out\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		waitForCondition(t, "external sign-out", func() bool {
			runtime := runtimeAuthTestObservation(c, command)
			return runtime["ready"] == false && runtime["status"] == "unavailable" &&
				runtime["readiness_issue"] == "authentication_required" &&
				mapParam(runtime, "auth")["status"] == "unauthenticated"
		})
	})
}

func TestRuntimeAuthSaturationDoesNotExhaustOrdinaryRequestAdmission(t *testing.T) {
	c, err := newConnector(config{name: "auth-admission", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeRuntimes)
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	c.runtimeInventory.runtimes[target.key()] = map[string]any{
		"kind": "external", "provider": "codex", "identity_material": target.identityMaterial,
	}
	for range cap(c.runtimeAuthSlots) {
		c.runtimeAuthSlots <- struct{}{}
	}
	t.Cleanup(func() {
		for range cap(c.runtimeAuthSlots) {
			<-c.runtimeAuthSlots
		}
	})

	replies := make(chan message, maxConcurrentRequests+1)
	session := newConnectionSession(c, context.Background(), func(_ context.Context, reply message) error {
		replies <- reply
		return nil
	}, nil)
	t.Cleanup(func() { session.close(context.Canceled) })
	for index := range maxConcurrentRequests {
		if !session.startConnectionRequest(message{
			ID: fmt.Sprintf("auth-%d", index), Type: "request", Method: "runtime_auth_read",
			Params: map[string]any{"provider": "codex", "identity_material": target.identityMaterial},
		}, nil) {
			t.Fatalf("auth request %d was not admitted for fail-fast handling", index)
		}
	}
	for range maxConcurrentRequests {
		reply := <-replies
		if reply.Type != "error" || !strings.Contains(reply.Error, "runtime auth capacity exhausted") {
			t.Fatalf("saturated auth reply = %#v", reply)
		}
	}
	waitForCondition(t, "fail-fast auth requests to release shared admission", func() bool {
		return len(c.requestSlots) == 0
	})

	if !session.startConnectionRequest(message{
		ID: "ordinary", Type: "request", Method: "process_list", Params: map[string]any{},
	}, nil) {
		t.Fatal("ordinary request was rejected after auth-lane saturation")
	}
	ordinary := <-replies
	if ordinary.ID != "ordinary" || ordinary.Type != "response" {
		t.Fatalf("ordinary request reply = %#v", ordinary)
	}
}

func newRuntimeAuthTestConnector(t *testing.T, fakeEnv map[string]string) (*connector, string, string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", "")
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	command := fakeCodexCommand(t, logPath, fakeEnv)
	t.Setenv("PATH", filepath.Dir(command))
	c, err := newConnector(config{name: "runtime-auth-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeRuntimes)
	if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
		t.Fatalf("initial runtime inventory: %v", err)
	}
	return c, command, logPath
}

func runtimeAuthTestObservation(c *connector, command string) map[string]any {
	for _, runtime := range c.runtimeInventory.snapshot() {
		if stringParam(runtime, "provider") == "codex" && stringParam(runtime, "identity_material") == command {
			return runtime
		}
	}
	return map[string]any{}
}

func TestRuntimeAuthAmbiguousCancelFencesAndClearsExactAttempt(t *testing.T) {
	dropMarker := filepath.Join(t.TempDir(), "drop-login-cancel-response-once")
	completionGate := filepath.Join(t.TempDir(), "complete-after-cancel")
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                    "none",
		"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_CANCEL_RESPONSE_ONCE": dropMarker,
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE":           completionGate,
	})
	manager := c.runtimeAuthCoordinator()
	manager.cancelTimeout = 50 * time.Millisecond
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	implementation.mu.Unlock()
	started, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	})
	if err != nil {
		t.Fatal(err)
	}
	canceled, err := c.methodRuntimeAuthLoginCancel(context.Background(), map[string]any{
		"provider":          "codex",
		"identity_material": command,
		"attempt_id":        started["attempt_id"],
	})
	if !runtimeAuthNativeOutcomeUnknown(err) {
		t.Fatalf("ambiguous cancel did not report unknown native outcome: %v", err)
	}
	if canceled["canceled"] != true || canceled["attempt_id"] != started["attempt_id"] ||
		mapParam(canceled, "auth")["issue"] != "login_failed" {
		t.Fatalf("ambiguous cancel terminal result = %#v", canceled)
	}
	if manager.attempt(runtimeProbeTarget{provider: "codex", identityMaterial: command}.key()) != nil {
		t.Fatal("ambiguous cancel retained a possibly-live Connector attempt")
	}
	implementation.mu.Lock()
	stillCurrent := implementation.runtimes[command] == runtime
	implementation.mu.Unlock()
	if stillCurrent {
		t.Fatal("ambiguous cancel left its native app-server generation current")
	}
	if err := os.WriteFile(completionGate, []byte("too-late\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// The cancel terminated the fenced generation; once it has exited it can
	// deliver nothing more. A generation left running never exits, and the go
	// test timeout reports it.
	<-runtime.done
	auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
	if auth["status"] == "authenticated" {
		t.Fatalf("completion after ambiguous cancel won: %#v", auth)
	}
	logData, _ := os.ReadFile(logPath)
	if !strings.Contains(string(logData), "account/login/cancel\n") {
		t.Fatalf("fake app-server never observed cancel dispatch; log:\n%s", logData)
	}
}

func runtimeAuthNativeOutcomeUnknown(err error) bool {
	var unknown *runtimeAuthNativeOutcomeUnknownError
	return errors.As(err, &unknown)
}
