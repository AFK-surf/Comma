package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
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
	if attemptID == "" || int64Param(started, "expires_at", 0) <= time.Now().UnixMilli() {
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
	waitForRuntimeAuthCondition(t, "authenticated runtime metadata", func() bool {
		runtime := runtimeAuthTestObservation(c, command)
		return runtime["ready"] == true && mapParam(runtime, "auth")["status"] == "authenticated"
	}, func() string {
		logData, _ := os.ReadFile(logPath)
		return fmt.Sprintf("runtime=%#v log=%s", runtimeAuthTestObservation(c, command), logData)
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

func TestComputeRuntimeAuthUsesExactCarrierTargetAndNativeCodexCeremony(t *testing.T) {
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeInstanceID = "runtime-1"
	c.cfg.computeRuntimeGeneration = 3
	c.cfg.computeRuntimeEpoch = "9"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	off := c.activateRuntimeTransport(runtimeOperationTestAuthority(c))
	defer off()
	session := computeRuntimeSession{instance: "runtime-1", epoch: "9", generation: 3, kind: "external_worker"}

	request := message{
		ID: "auth-1", Type: "request", Method: "runtime_auth_login_start",
		Params: map[string]any{
			"target": map[string]any{
				"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
				"runtime_instance_id": "runtime-1", "generation": 3,
				"connection_epoch": "9", "provider": "codex",
			},
			"flow": "device_code",
		},
	}

	reply := c.computeRuntimeAuthReply(context.Background(), request, session)
	result, ok := reply.Result.(map[string]any)
	if !ok || reply.Type != "response" || result["flow"] != "device_code" ||
		result["verification_url"] != "https://auth.openai.com/codex/device" ||
		result["user_code"] != "ABCD-EFGH" {
		t.Fatalf("compute auth reply = %#v", reply)
	}
	encoded := fmt.Sprint(reply.Result)
	for _, forbidden := range []string{"access_token", "refresh_token", "auth.json", "private@example.test"} {
		if strings.Contains(encoded, forbidden) {
			t.Fatalf("compute auth reply leaked %q: %s", forbidden, encoded)
		}
	}

	stale := request
	stale.ID = "auth-stale"
	stale.Params = map[string]any{
		"target": map[string]any{
			"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
			"runtime_instance_id": "runtime-1", "generation": 3,
			"connection_epoch": "8", "provider": "codex",
		},
		"flow": "device_code",
	}
	staleReply := c.computeRuntimeAuthReply(context.Background(), stale, session)
	if staleReply.Type != "error" || staleReply.Error != "compute runtime auth target rejected" {
		t.Fatalf("stale compute auth reply = %#v", staleReply)
	}

	wrongTenant := request
	wrongTenant.ID = "auth-wrong-tenant"
	wrongTenant.Params = map[string]any{
		"target": map[string]any{
			"tenant_id": "other-tenant", "project_id": "project", "workload_id": "workload-1",
			"runtime_instance_id": "runtime-1", "generation": 3,
			"connection_epoch": "9", "provider": "codex",
		},
		"flow": "device_code",
	}
	wrongTenantReply := c.computeRuntimeAuthReply(context.Background(), wrongTenant, session)
	if wrongTenantReply.Type != "error" || wrongTenantReply.Error != "compute runtime auth target rejected" {
		t.Fatalf("wrong-tenant compute auth reply = %#v", wrongTenantReply)
	}
}

func TestComputeRuntimeAuthReleaseFailureIsActionRequired(t *testing.T) {
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeInstanceID = "runtime-1"
	c.cfg.computeRuntimeGeneration = 3
	c.cfg.computeRuntimeEpoch = "9"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	c.setComputeRuntimeExecutionTarget(map[string]any{
		"runtime_instance_id": "runtime-1", "runtime_generation": 3,
		"runtime_connection_epoch": "9", "workload_id": "workload-1", "workload_generation": 3,
		"allocation_id": "allocation", "allocation_generation": 1,
		"container_id": "container", "container_instance_id": "container-instance",
	})
	send := func(_ context.Context, request message) error {
		if request.Method != "runtime_execution" {
			return nil
		}
		result := map[string]any{
			"execution_id":          stringParam(request.Params, "execution_id"),
			"container_instance_id": "container-instance",
		}
		switch stringParam(request.Params, "action") {
		case "acquire":
			result["acquired"] = true
		case "release":
			result["released"] = false
		default:
			return fmt.Errorf("unexpected runtime execution action %q", stringParam(request.Params, "action"))
		}
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: result})
		return nil
	}
	off := c.activateRuntimeTransport(send)
	defer off()
	carrier := c.getActiveTransport()
	session := computeRuntimeSession{instance: "runtime-1", epoch: "9", generation: 3, kind: "external_worker"}
	target := map[string]any{
		"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
		"runtime_instance_id": "runtime-1", "generation": 3, "connection_epoch": "9",
		"provider": "codex", "actor_id": "admin",
	}
	statusParams := map[string]any{"target": target}
	key := runtimeAuthOperationKey(statusParams)
	if _, err := c.runtimeOperations.beginAcquire(key, key, "auth_operation", c.currentComputeRuntimeExecutionTarget()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.runtimeOperations.finishAcquire(key, true, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c.computePrivateRuntimeAuthOwned(context.Background(), message{
		ID: "status", Method: "runtime_auth_status", Params: statusParams,
	}, session, carrier); err == nil || !strings.Contains(err.Error(), "action required") {
		t.Fatalf("terminal status masked release failure: %v", err)
	}

	c.runtimeOperations.finishSettlement(key, nil)
	loginTarget := map[string]any{}
	for k, v := range target {
		if k != "actor_id" {
			loginTarget[k] = v
		}
	}
	reply := c.computeRuntimeAuthReplyAdmitted(context.Background(), message{
		ID: "login", Method: "runtime_auth_login_start",
		Params: map[string]any{"target": loginTarget, "flow": "unsupported"},
	}, session, carrier)
	if reply.Type != "error" || !strings.Contains(reply.Error, "action required") {
		t.Fatalf("login-start failure masked release failure: %#v", reply)
	}
}

func TestComputeRuntimeAuthLoginCancelRejectsRecoveredFamily(t *testing.T) {
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeInstanceID = "runtime-1"
	c.cfg.computeRuntimeGeneration = 3
	c.cfg.computeRuntimeEpoch = "9"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	executionTarget := map[string]any{
		"runtime_instance_id": "runtime-1", "runtime_generation": 3,
		"runtime_connection_epoch": "9", "workload_id": "workload-1", "workload_generation": 3,
		"allocation_id": "allocation", "allocation_generation": 1,
		"container_id": "container", "container_instance_id": "container-instance",
	}
	c.setComputeRuntimeExecutionTarget(executionTarget)
	target := map[string]any{
		"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
		"runtime_instance_id": "runtime-1", "generation": 3, "connection_epoch": "9",
		"provider": "codex",
	}
	params := map[string]any{"target": target}
	familyID := runtimeAuthOperationKey(params)
	activityID := familyID + ":verify:lost-request"
	if _, err := c.runtimeOperations.beginAcquire(familyID, activityID, "auth_operation", executionTarget); err != nil {
		t.Fatal(err)
	}
	if _, err := c.runtimeOperations.finishAcquire(activityID, false, errors.New("acquire reply lost")); err == nil {
		t.Fatal("test setup did not enter recovered-unknown")
	}

	reply := c.computeRuntimeAuthReplyAdmitted(context.Background(), message{
		ID: "cancel", Method: "runtime_auth_login_cancel", Params: params,
	}, computeRuntimeSession{instance: "runtime-1", epoch: "9", generation: 3, kind: "external_worker"}, nil)
	if reply.Type != "error" || !strings.Contains(reply.Error, "action required") {
		t.Fatalf("login cancel crossed a recovered auth family: %#v", reply)
	}
}

func TestComputeRuntimeAuthReadsPortableNativeReadinessWithoutCodexCeremony(t *testing.T) {
	for _, provider := range []string{"pi", "claude"} {
		for _, authReady := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s-auth-ready-%t", provider, authReady), func(t *testing.T) {
				t.Setenv("HOME", t.TempDir())
				var command string
				if provider == "pi" {
					t.Setenv("SALIX_TEST_FAKE_PI_AUTH_READY", map[bool]string{true: "1", false: "0"}[authReady])
					command = fakePortableRuntimeCommand(t, "pi")
				} else {
					t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", map[bool]string{true: "authenticated", false: "signed_out"}[authReady])
					command = fakeClaudeRuntimeCommand(t)
				}
				t.Setenv("PATH", filepath.Dir(command))
				c, err := newConnector(config{name: provider + "-compute-auth", root: t.TempDir(), systemInfoInterval: 0})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(c.closeExternalRuntimes)
				if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
					t.Fatalf("initial runtime inventory: %v", err)
				}
				c.cfg.computeRuntimeWorkloadID = "workload-" + provider
				c.cfg.computeRuntimeInstanceID = "runtime-" + provider
				c.cfg.computeRuntimeGeneration = 2
				c.cfg.computeRuntimeEpoch = "7"
				c.cfg.computeRuntimeKind = "external_worker"
				c.cfg.computeRuntimeProvider = provider
				c.cfg.computeRuntimeTenantID = "tenant"
				c.cfg.computeRuntimeProjectID = "project"
				session := computeRuntimeSession{instance: "runtime-" + provider, epoch: "7", generation: 2, kind: "external_worker"}
				request := message{
					ID: "auth-" + provider, Type: "request", Method: "runtime_auth_read",
					Params: map[string]any{"target": map[string]any{
						"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-" + provider,
						"runtime_instance_id": "runtime-" + provider, "generation": 2,
						"connection_epoch": "7", "provider": provider,
					}},
				}

				reply := c.computeRuntimeAuthReply(context.Background(), request, session)
				result, ok := reply.Result.(map[string]any)
				if !ok || reply.Type != "response" {
					t.Fatalf("%s compute auth reply = %#v", provider, reply)
				}
				auth := mapParam(result, "auth")
				wantStatus := map[bool]string{true: "authenticated", false: "unauthenticated"}[authReady]
				wantReady := authReady
				if provider == "pi" && authReady {
					wantStatus, wantReady = "configured", false
				}
				if auth["status"] != wantStatus || auth["requires_openai_auth"] != false || result["ready"] != wantReady {
					t.Fatalf("%s compute auth result = %#v, want status=%s ready=%t", provider, result, wantStatus, authReady)
				}
				if provider == "pi" && auth["mode"] != nil {
					t.Fatalf("Pi local model list must not infer a credential mode: %#v", auth)
				}
				if provider == "claude" {
					if _, ok := auth["mode"]; ok {
						t.Fatalf("Claude auth result inferred a credential mode: %#v", auth)
					}
				}
				if result["native_ready"] != true {
					t.Fatalf("%s native readiness = %#v, want true", provider, result)
				}
				encoded := fmt.Sprint(result)
				for _, forbidden := range []string{"secret-token", "person@example.com", command, "identity_material", "last_error"} {
					if strings.Contains(encoded, forbidden) {
						t.Fatalf("%s compute auth result leaked %q: %s", provider, forbidden, encoded)
					}
				}
			})
		}
	}
}

func TestComputeRuntimeCarrierRoundTripsNativeCodexCeremony(t *testing.T) {
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})

	responses := make(chan message, 1)
	serverErrors := make(chan error, 1)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverErrors <- err
			return
		}
		defer conn.Close()

		var hello map[string]any
		if err := conn.ReadJSON(&hello); err != nil {
			serverErrors <- err
			return
		}
		if !jsonStringListContains(hello["supported_features"], "runtime.auth.v1") {
			serverErrors <- fmt.Errorf("runtime auth feature was not negotiated: %#v", hello)
			return
		}
		if err := conn.WriteJSON(map[string]any{
			"type": "runtime.ready", "runtime_instance_id": "runtime-1",
			"workload_id": "workload-1", "generation": 3,
			"runtime_kind": "external_worker", "connection_epoch": "9",
			"features":     []string{"runtime.input.v1", "runtime.event.v1", "runtime.auth.v1", "runtime.execution.v1"},
			"input_cursor": "", "event_cursor": "", "token": "runtime-token",
			"execution_target": map[string]any{
				"runtime_instance_id": "runtime-1", "runtime_generation": 3,
				"runtime_connection_epoch": "9", "workload_id": "workload-1", "workload_generation": 3,
				"allocation_id": "allocation-1", "allocation_generation": 1,
				"container_id": "container-1", "container_instance_id": "container-instance-1",
			},
		}); err != nil {
			serverErrors <- err
			return
		}
		if err := acknowledgeRuntimeOperationList(conn, nil); err != nil {
			serverErrors <- err
			return
		}
		if err := awaitRuntimeOperationReconciliation(conn); err != nil {
			serverErrors <- err
			return
		}
		if err := conn.WriteJSON(map[string]any{
			"type": "request", "id": "auth-over-wss", "method": "runtime_auth_login_start",
			"params": map[string]any{
				"target": map[string]any{
					"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
					"runtime_instance_id": "runtime-1", "generation": 3,
					"connection_epoch": "9", "provider": "codex",
				},
				"flow": "device_code",
			},
		}); err != nil {
			serverErrors <- err
			return
		}

		var acquire message
		if err := conn.ReadJSON(&acquire); err != nil {
			serverErrors <- err
			return
		}
		if acquire.Method != "runtime_execution" || stringParam(acquire.Params, "action") != "acquire" || stringParam(acquire.Params, "kind") != "auth_operation" {
			serverErrors <- fmt.Errorf("unexpected auth ownership request: %#v", acquire)
			return
		}
		if err := conn.WriteJSON(message{ID: acquire.ID, Type: "response", Result: map[string]any{
			"execution_id": stringParam(acquire.Params, "execution_id"), "container_instance_id": "container-instance-1", "acquired": true,
		}}); err != nil {
			serverErrors <- err
			return
		}
		var response message
		if err := conn.ReadJSON(&response); err != nil {
			serverErrors <- err
			return
		}
		responses <- response
	}))
	defer server.Close()

	c.cfg.computeRuntimeURL = server.URL
	c.cfg.computeRuntimeBootstrapToken = "bootstrap"
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeInstanceID = "runtime-1"
	c.cfg.computeRuntimeGeneration = 3
	c.cfg.computeRuntimeEpoch = "9"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		c.computeRuntimeInputLoop(ctx)
		close(done)
	}()

	select {
	case response := <-responses:
		result, ok := response.Result.(map[string]any)
		if !ok || response.Type != "response" || result["flow"] != "device_code" ||
			result["user_code"] != "ABCD-EFGH" {
			t.Fatalf("auth response = %#v", response)
		}
		if strings.Contains(fmt.Sprint(result), "access_token") {
			t.Fatalf("auth response leaked provider credential: %#v", result)
		}
	case err := <-serverErrors:
		t.Fatalf("runtime auth WSS server: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("runtime auth WSS response timed out")
	}

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("compute runtime input loop did not stop")
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
	select {
	case first = <-firstAuthenticated:
	case <-time.After(5 * time.Second):
		t.Fatal("authenticated incremental metadata was not published")
	}
	if first["auth_ready"] != true || first["ready"] != false || first["status"] != "unavailable" {
		t.Fatalf("authentication bypassed full readiness probe: %#v", first)
	}
	releaseOnce.Do(func() { close(releasePublication) })
	waitForRuntimeAuthCondition(t, "model-unavailable full probe", func() bool {
		runtime := runtimeAuthTestObservation(c, command)
		return mapParam(runtime, "auth")["status"] == "authenticated" &&
			runtime["ready"] == false && runtime["readiness_issue"] == "model_unavailable"
	}, func() string { return fmt.Sprintf("%#v", runtimeAuthTestObservation(c, command)) })
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
	select {
	case <-oldRuntime.done:
	case <-time.After(5 * time.Second):
		t.Fatal("G1 did not stop")
	}
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
	select {
	case first = <-firstG2Auth:
	case <-time.After(5 * time.Second):
		t.Fatal("G2 incremental authentication metadata was not published")
	}
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
	select {
	case result := <-readDone:
		if result.err != nil || mapParam(result.read, "auth")["status"] != "authenticated" {
			t.Fatalf("G2 runtime auth read = %#v, %v", result.read, result.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("G2 full readiness probe did not complete")
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
	waitForRuntimeAuthCondition(t, "dead websocket generation retirement", func() bool {
		implementation.mu.Lock()
		defer implementation.mu.Unlock()
		return implementation.runtimes[command] != oldRuntime
	}, func() string { return fmt.Sprintf("old runtime running=%v", oldRuntime.isRunning()) })
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

func TestRuntimeAuthLateOldGenerationCallbackPreservesReboundSession(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	oldRuntime := implementation.runtimes[command]
	session := &codexRuntimeSession{
		sessionID:       "rebound-before-old-close",
		token:           "g1-token",
		threadID:        "thread-g1",
		workState:       "settled",
		runtime:         oldRuntime,
		recoveryPending: false,
	}
	implementation.sessions[session.sessionID] = session
	implementation.mu.Unlock()
	if oldRuntime == nil {
		t.Fatal("initial inventory did not retain G1")
	}

	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	unlockTarget := c.runtimeAuthCoordinator().lockTarget(target.key())
	released := false
	defer func() {
		if !released {
			unlockTarget()
		}
	}()
	implementation.retireUnusableRuntimeGeneration(oldRuntime)
	select {
	case <-oldRuntime.exited:
	case <-time.After(5 * time.Second):
		t.Fatal("G1 did not exit")
	}
	select {
	case <-oldRuntime.done:
		t.Fatal("G1 callback bypassed the held target lock")
	case <-time.After(50 * time.Millisecond):
	}

	input := externalRuntimeInput{
		command:   command,
		sessionID: session.sessionID,
		token:     "g2-token",
		workspace: c.root,
	}
	newRuntime, err := implementation.ensureRuntime(context.Background(), input, session)
	if err != nil {
		t.Fatalf("start G2 while G1 callback is blocked: %v", err)
	}
	if err := newRuntime.ensureInitialized(context.Background()); err != nil {
		t.Fatalf("initialize G2 while G1 callback is blocked: %v", err)
	}
	if newRuntime == oldRuntime || newRuntime.generation == oldRuntime.generation {
		t.Fatalf("rebind did not create G2: G1=%#v G2=%#v", oldRuntime, newRuntime)
	}

	unlockTarget()
	released = true
	select {
	case <-oldRuntime.done:
	case <-time.After(5 * time.Second):
		t.Fatal("late G1 callback did not finish")
	}

	implementation.mu.Lock()
	current := implementation.runtimes[command]
	implementation.mu.Unlock()
	session.mu.Lock()
	boundRuntime := session.runtime
	token := session.token
	threadID := session.threadID
	workState := session.workState
	recoveryPending := session.recoveryPending
	session.mu.Unlock()
	if current != newRuntime || boundRuntime != newRuntime || !newRuntime.isRunning() {
		t.Fatalf("late G1 callback clobbered G2: current=%#v bound=%#v G2=%#v", current, boundRuntime, newRuntime)
	}
	if token != "g2-token" || threadID != "thread-g1" || workState != "settled" || recoveryPending {
		t.Fatalf(
			"late G1 callback mutated rebound session: token=%q thread=%q state=%q recovery_pending=%v",
			token, threadID, workState, recoveryPending,
		)
	}
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
	select {
	case <-runtime.done:
	case <-time.After(5 * time.Second):
		t.Fatal("initial Codex app-server did not stop")
	}
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

	select {
	case result := <-done:
		if result.err != nil {
			t.Fatalf("runtime auth read: %v", result.err)
		}
		return result.read
	case <-time.After(2 * time.Second):
		// Releasing the caller context makes the pre-fix wait-on-done cycle
		// unwind, so a failing regression still cleans up its child process.
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
		t.Fatal("runtime auth read deadlocked behind its own target lock")
		return nil
	}
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
	t.Cleanup(c.closeExternalRuntimes)
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

func waitForRuntimeAuthCondition(t *testing.T, description string, condition func() bool, detail func() string) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s: %s", description, detail())
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

func readRuntimeAuthWebSocketReply(t *testing.T, ws *websocket.Conn, id string) message {
	t.Helper()
	if err := ws.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	defer ws.SetReadDeadline(time.Time{})
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
		waitForRuntimeAuthCondition(t, "safe login failure", func() bool {
			auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
			return auth["status"] == "error" && auth["issue"] == "login_failed"
		}, func() string { return fmt.Sprintf("%#v", runtimeAuthTestObservation(c, command)) })
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
		c.runtimeAuthCoordinator().ttl = time.Millisecond
		_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		if err != nil {
			t.Fatal(err)
		}
		time.Sleep(5 * time.Millisecond)
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
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":           "none",
			"SALIX_TEST_FAKE_CODEX_EXIT_AFTER_LOGIN_START": "1",
		})
		_, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		})
		if err != nil {
			t.Fatal(err)
		}
		waitForRuntimeAuthCondition(t, "runtime-exit auth failure", func() bool {
			auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
			return auth["status"] == "error" && auth["issue"] == "login_failed"
		}, func() string { return fmt.Sprintf("%#v", runtimeAuthTestObservation(c, command)) })
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
		waitForRuntimeAuthCondition(t, "exit-raced attempt cleanup", func() bool {
			return c.runtimeAuthCoordinator().attempt(target.key()) == nil
		}, func() string {
			return fmt.Sprintf("attempt=%#v", c.runtimeAuthCoordinator().attempt(target.key()))
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

func TestComputeRuntimeAuthAmbiguousLoginStartKeepsHostRightAndRejectsQuiet(t *testing.T) {
	dropMarker := filepath.Join(t.TempDir(), "drop-compute-login-start-response-once")
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                   "none",
		"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_START_RESPONSE_ONCE": dropMarker,
	})
	c.runtimeAuthCoordinator().startTimeout = 50 * time.Millisecond
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeInstanceID = "runtime-1"
	c.cfg.computeRuntimeGeneration = 3
	c.cfg.computeRuntimeEpoch = "9"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	off := c.activateRuntimeTransport(runtimeOperationTestAuthority(c))
	defer off()

	target := map[string]any{
		"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
		"runtime_instance_id": "runtime-1", "generation": 3,
		"connection_epoch": "9", "provider": "codex",
	}
	params := map[string]any{"target": target, "flow": "device_code"}
	reply := c.computeRuntimeAuthReply(context.Background(), message{
		ID: "ambiguous-login", Type: "request", Method: "runtime_auth_login_start", Params: params,
	}, computeRuntimeSession{instance: "runtime-1", epoch: "9", generation: 3, kind: "external_worker"})
	if reply.Type != "error" || !strings.Contains(reply.Error, "action required") {
		t.Fatalf("ambiguous login reply = %#v", reply)
	}
	key := runtimeAuthOperationKey(params)
	if right, ok := c.runtimeOperations.familyState(key); !ok || right.ActivityID != key {
		t.Fatalf("ambiguous login released Host right: %#v", c.runtimeOperations.snapshot())
	}
	if _, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "codex"}); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("quiet admitted ambiguous native login: %v", err)
	}
}

func TestComputeRuntimeAuthAmbiguousLoginCancelKeepsHostRightAndRejectsQuiet(t *testing.T) {
	dropMarker := filepath.Join(t.TempDir(), "drop-compute-login-cancel-response-once")
	completionGate := filepath.Join(t.TempDir(), "complete-compute-login-after-cancel")
	c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                    "none",
		"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_CANCEL_RESPONSE_ONCE": dropMarker,
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE":           completionGate,
	})
	c.runtimeAuthCoordinator().cancelTimeout = 50 * time.Millisecond
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeInstanceID = "runtime-1"
	c.cfg.computeRuntimeGeneration = 3
	c.cfg.computeRuntimeEpoch = "9"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	off := c.activateRuntimeTransport(runtimeOperationTestAuthority(c))
	defer off()
	session := computeRuntimeSession{instance: "runtime-1", epoch: "9", generation: 3, kind: "external_worker"}
	target := map[string]any{
		"tenant_id": "tenant", "project_id": "project", "workload_id": "workload-1",
		"runtime_instance_id": "runtime-1", "generation": 3,
		"connection_epoch": "9", "provider": "codex",
	}
	startParams := map[string]any{"target": target, "flow": "device_code"}
	started := c.computeRuntimeAuthReply(context.Background(), message{
		ID: "login", Type: "request", Method: "runtime_auth_login_start", Params: startParams,
	}, session)
	result, ok := started.Result.(map[string]any)
	if !ok || started.Type != "response" || stringParam(result, "attempt_id") == "" {
		t.Fatalf("login start = %#v", started)
	}
	cancelParams := map[string]any{"target": target, "attempt_id": result["attempt_id"]}
	canceled := c.computeRuntimeAuthReply(context.Background(), message{
		ID: "cancel", Type: "request", Method: "runtime_auth_login_cancel", Params: cancelParams,
	}, session)
	if canceled.Type != "error" || !strings.Contains(canceled.Error, "action required") {
		t.Fatalf("ambiguous cancel reply = %#v", canceled)
	}
	key := runtimeAuthOperationKey(cancelParams)
	if right, ok := c.runtimeOperations.familyState(key); !ok || right.ActivityID != key {
		t.Fatalf("ambiguous cancel released Host right: %#v", c.runtimeOperations.snapshot())
	}
	if _, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "codex"}); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("quiet admitted ambiguous native cancellation: %v", err)
	}
}

func TestRuntimeAuthAmbiguousStartQuarantinesSessionBoundGeneration(t *testing.T) {
	dropMarker := filepath.Join(t.TempDir(), "drop-bound-login-start-response-once")
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                   "none",
		"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_START_RESPONSE_ONCE": dropMarker,
	})
	manager := c.runtimeAuthCoordinator()
	manager.startTimeout = 50 * time.Millisecond
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	boundSession := &codexRuntimeSession{sessionID: "bound-auth-quarantine", runtime: runtime}
	implementation.sessions[boundSession.sessionID] = boundSession
	implementation.mu.Unlock()
	params := map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), params); err == nil {
		t.Fatal("dropped response on session-bound runtime unexpectedly succeeded")
	}
	implementation.mu.Lock()
	current := implementation.runtimes[command]
	quarantined := implementation.authQuarantined[runtime.generation]
	implementation.mu.Unlock()
	if current != runtime || !quarantined || !runtime.isRunning() {
		t.Fatalf("session-bound runtime was disrupted: current=%#v runtime=%#v quarantined=%v", current, runtime, quarantined)
	}
	boundSession.mu.Lock()
	stillBound := boundSession.runtime == runtime
	boundSession.mu.Unlock()
	if !stillBound {
		t.Fatal("auth quarantine rebound or cleared the existing runtime session")
	}
	if _, err := runtime.rpc(
		context.Background(),
		"account/read",
		map[string]any{"refreshToken": false},
		time.Second,
	); err != nil {
		t.Fatalf("session-bound quarantined app-server stopped serving ordinary RPC: %v", err)
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), params); err == nil ||
		!strings.Contains(err.Error(), "probe failed") {
		t.Fatalf("quarantined generation admitted a second auth start: %v", err)
	}
	probeCtx, cancelProbe := context.WithTimeout(context.Background(), time.Second)
	runtimes, err := c.runtimeInventory.probe(probeCtx, "codex", command, "operator")
	cancelProbe()
	if err != nil || len(runtimes) != 1 || mapParam(runtimes[0], "auth")["issue"] != "login_failed" {
		t.Fatalf("quarantined generation did not return cached safe probe promptly: runtimes=%#v err=%v", runtimes, err)
	}
	if err := os.Chmod(command, 0o600); err != nil {
		t.Fatal(err)
	}
	probeCtx, cancelProbe = context.WithTimeout(context.Background(), time.Second)
	runtimes, err = c.runtimeInventory.probe(probeCtx, "codex", command, "operator")
	cancelProbe()
	if err != nil || len(runtimes) != 1 || mapParam(runtimes[0], "auth")["issue"] != "login_failed" {
		t.Fatalf("version-failing quarantined generation did not return cached safe probe promptly: runtimes=%#v err=%v", runtimes, err)
	}
	logData, _ := os.ReadFile(logPath)
	if got := strings.Count(string(logData), "account/login/start\n"); got != 1 {
		t.Fatalf("quarantined generation dispatched %d native login starts; log:\n%s", got, logData)
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
	time.Sleep(75 * time.Millisecond)
	auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
	if auth["status"] == "authenticated" {
		t.Fatalf("completion after ambiguous cancel won: %#v", auth)
	}
	logData, _ := os.ReadFile(logPath)
	if !strings.Contains(string(logData), "account/login/cancel\n") {
		t.Fatalf("fake app-server never observed cancel dispatch; log:\n%s", logData)
	}
}

func TestRuntimeAuthAmbiguousCancelQuarantinesSessionBoundGeneration(t *testing.T) {
	dropMarker := filepath.Join(t.TempDir(), "drop-bound-login-cancel-response-once")
	completionGate := filepath.Join(t.TempDir(), "complete-after-bound-cancel")
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                    "none",
		"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_CANCEL_RESPONSE_ONCE": dropMarker,
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE":           completionGate,
	})
	manager := c.runtimeAuthCoordinator()
	manager.cancelTimeout = 50 * time.Millisecond
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	implementation.mu.Lock()
	runtime := implementation.runtimes[command]
	boundSession := &codexRuntimeSession{sessionID: "bound-cancel-quarantine", runtime: runtime}
	implementation.sessions[boundSession.sessionID] = boundSession
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
	if !runtimeAuthNativeOutcomeUnknown(err) || canceled["canceled"] != true || mapParam(canceled, "auth")["issue"] != "login_failed" {
		t.Fatalf("session-bound ambiguous cancel = %#v, %v", canceled, err)
	}
	implementation.mu.Lock()
	current := implementation.runtimes[command]
	quarantined := implementation.authQuarantined[runtime.generation]
	implementation.mu.Unlock()
	boundSession.mu.Lock()
	stillBound := boundSession.runtime == runtime
	boundSession.mu.Unlock()
	if current != runtime || !runtime.isRunning() || !quarantined || !stillBound {
		t.Fatalf("session-bound cancel disrupted runtime: current=%#v runtime=%#v quarantined=%v bound=%v", current, runtime, quarantined, stillBound)
	}
	if _, err := runtime.rpc(
		context.Background(),
		"account/read",
		map[string]any{"refreshToken": false},
		time.Second,
	); err != nil {
		t.Fatalf("session-bound cancel quarantine stopped ordinary RPC: %v", err)
	}
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}); err == nil || !strings.Contains(err.Error(), "probe failed") {
		t.Fatalf("cancel-quarantined generation admitted a second auth start: %v", err)
	}
	if err := os.WriteFile(completionGate, []byte("too-late\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	time.Sleep(75 * time.Millisecond)
	probeCtx, cancelProbe := context.WithTimeout(context.Background(), time.Second)
	runtimes, probeErr := c.runtimeInventory.probe(probeCtx, "codex", command, "operator")
	cancelProbe()
	if probeErr != nil || len(runtimes) != 1 || mapParam(runtimes[0], "auth")["issue"] != "login_failed" {
		t.Fatalf("cancel-quarantined generation lost safe cached state: runtimes=%#v err=%v", runtimes, probeErr)
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
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
		"provider": "codex", "identity_material": command, "flow": "device_code",
	}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Millisecond)
	if err := os.WriteFile(completionGate, []byte("complete\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	waitForRuntimeAuthCondition(t, "late completion timeout fence", func() bool {
		auth := mapParam(runtimeAuthTestObservation(c, command), "auth")
		return auth["status"] == "error" && auth["issue"] == "login_timeout" &&
			manager.attempt(target.key()) == nil
	}, func() string {
		logData, _ := os.ReadFile(logPath)
		return fmt.Sprintf("runtime=%#v attempt=%#v log=%s", runtimeAuthTestObservation(c, command), manager.attempt(target.key()), logData)
	})
	time.Sleep(50 * time.Millisecond)
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
	waitForRuntimeAuthCondition(t, "blocked notification account/read", func() bool {
		logData, _ := os.ReadFile(logPath)
		return strings.Count(string(logData), "account/read\n") > baselineReads
	}, func() string {
		logData, _ := os.ReadFile(logPath)
		return string(logData)
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
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := c.methodRuntimeAuthRead(ctx, map[string]any{
			"provider": "codex", "identity_material": command,
		})
		readDone <- err
	}()
	if err := os.WriteFile(readGate, []byte("open\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readDone:
		if err != nil {
			t.Fatalf("foreground read after notification flood: %v", err)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("coalesced notification flood starved foreground auth read")
	}
	waitForRuntimeAuthCondition(t, "notification worker drain", func() bool {
		manager.mu.Lock()
		defer manager.mu.Unlock()
		return len(manager.notifications) == 0
	}, func() string {
		manager.mu.Lock()
		defer manager.mu.Unlock()
		return fmt.Sprintf("states=%d", len(manager.notifications))
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
		codexAuthIssueSnapshot("auth_probe_failed", time.Now().UnixMilli()),
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
	newer := codexPendingAuthSnapshot(time.Now().UnixMilli())
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
				codexAuthIssueSnapshot("auth_probe_failed", time.Now().UnixMilli()),
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
	select {
	case <-firstReady:
	case <-time.After(5 * time.Second):
		t.Fatal("initial in-flight probe did not reach its publication fence")
	}
	newer := codexPendingAuthSnapshot(time.Now().UnixMilli())
	if !c.runtimeAuthCoordinator().publishSnapshotForRuntime(target, runtime, newer) {
		t.Fatal("failed to publish incremental same-generation auth observation")
	}
	close(firstRelease)
	select {
	case <-secondReady:
	case <-time.After(5 * time.Second):
		t.Fatal("stale in-flight probe did not retry after auth epoch advanced")
	}
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
	stopCtx, cancelStop := context.WithTimeout(context.Background(), 5*time.Second)
	if err := stopExternalRuntime(stopCtx, oldRuntime.terminate, oldRuntime.done); err != nil {
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
		expiresAt:         time.Now().Add(time.Minute).UnixMilli(),
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
	waitForRuntimeAuthCondition(t, "superseded native attempt cancellation", func() bool {
		logData, _ := os.ReadFile(logPath)
		return mapParam(runtimeAuthTestObservation(c, command), "auth")["status"] == "authenticated" &&
			c.runtimeAuthCoordinator().attempt(runtimeProbeTarget{
				provider: "codex", identityMaterial: command,
			}.key()) == nil && strings.Contains(string(logData), "account/login/cancel\n")
	}, func() string {
		logData, _ := os.ReadFile(logPath)
		return fmt.Sprintf("runtime=%#v log=%s", runtimeAuthTestObservation(c, command), logData)
	})
	if _, err := c.methodRuntimeAuthLoginStart(context.Background(), params); err == nil ||
		!strings.Contains(err.Error(), "already authenticated") {
		t.Fatalf("new login after external authentication error = %v", err)
	}
}

func TestRuntimeAuthAmbiguousSupersessionPublishesTerminalBeforeQuarantine(t *testing.T) {
	type fixture struct {
		c              *connector
		command        string
		cancelDropPath string
		implementation *codexRuntimeImplementation
		manager        *runtimeAuthCoordinator
		runtime        *codexRuntime
		boundSession   *codexRuntimeSession
	}
	setup := func(t *testing.T) fixture {
		t.Helper()
		authenticatedMarker := filepath.Join(t.TempDir(), "externally-authenticated")
		cancelDropPath := filepath.Join(t.TempDir(), "drop-superseded-cancel-once")
		c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
			"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":                    "none",
			"SALIX_TEST_FAKE_CODEX_AUTH_SUCCESS_WHILE_EXISTS":       authenticatedMarker,
			"SALIX_TEST_FAKE_CODEX_DROP_LOGIN_CANCEL_RESPONSE_ONCE": cancelDropPath,
		})
		manager := c.runtimeAuthCoordinator()
		manager.nativeCancelTimeout = 50 * time.Millisecond
		implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
		implementation.mu.Lock()
		runtime := implementation.runtimes[command]
		boundSession := &codexRuntimeSession{
			sessionID: "bound-ambiguous-supersession",
			runtime:   runtime,
		}
		implementation.sessions[boundSession.sessionID] = boundSession
		implementation.mu.Unlock()
		if runtime == nil {
			t.Fatal("initial inventory did not retain a Codex app-server")
		}
		if _, err := c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": command, "flow": "device_code",
		}); err != nil {
			t.Fatal(err)
		}
		if auth := mapParam(runtimeAuthTestObservation(c, command), "auth"); auth["status"] != "pending" {
			t.Fatalf("login did not publish pending before supersession: %#v", auth)
		}
		if err := os.WriteFile(authenticatedMarker, []byte("authenticated\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return fixture{
			c: c, command: command, cancelDropPath: cancelDropPath,
			implementation: implementation, manager: manager, runtime: runtime,
			boundSession: boundSession,
		}
	}
	assertTerminal := func(t *testing.T, f fixture) {
		t.Helper()
		target := runtimeProbeTarget{provider: "codex", identityMaterial: f.command}
		if attempt := f.manager.attempt(target.key()); attempt != nil {
			t.Fatalf("ambiguous supersession retained attempt: %#v", attempt)
		}
		f.implementation.mu.Lock()
		current := f.implementation.runtimes[f.command]
		quarantined := f.implementation.authQuarantined[f.runtime.generation]
		f.implementation.mu.Unlock()
		f.boundSession.mu.Lock()
		stillBound := f.boundSession.runtime == f.runtime
		f.boundSession.mu.Unlock()
		if current != f.runtime || !f.runtime.isRunning() || !quarantined || !stillBound {
			t.Fatalf(
				"ambiguous supersession disrupted bound runtime: current=%#v runtime=%#v quarantined=%v bound=%v",
				current, f.runtime, quarantined, stillBound,
			)
		}
		cached := runtimeAuthTestObservation(f.c, f.command)
		auth := mapParam(cached, "auth")
		if auth["status"] != "error" || auth["issue"] != "login_failed" ||
			cached["ready"] != false || cached["status"] != "unavailable" {
			t.Fatalf("reload-visible cache retained stale pending state: %#v", cached)
		}
		probeCtx, cancelProbe := context.WithTimeout(context.Background(), time.Second)
		runtimes, err := f.c.runtimeInventory.probe(probeCtx, "codex", f.command, "operator")
		cancelProbe()
		if err != nil || len(runtimes) != 1 ||
			mapParam(runtimes[0], "auth")["issue"] != "login_failed" {
			t.Fatalf("quarantined reload did not preserve terminal cache: runtimes=%#v err=%v", runtimes, err)
		}
		if _, err := f.c.methodRuntimeAuthLoginStart(context.Background(), map[string]any{
			"provider": "codex", "identity_material": f.command, "flow": "device_code",
		}); err == nil || !strings.Contains(err.Error(), "probe failed") {
			t.Fatalf("quarantined superseded generation admitted a new login: %v", err)
		}
		if _, err := f.runtime.rpc(
			context.Background(),
			"account/read",
			map[string]any{"refreshToken": false},
			time.Second,
		); err != nil {
			t.Fatalf("auth quarantine stopped ordinary bound-session RPC: %v", err)
		}
		if _, err := os.Stat(f.cancelDropPath); err != nil {
			t.Fatalf("native cancel response was not dropped: %v", err)
		}
	}

	t.Run("foreground read", func(t *testing.T) {
		f := setup(t)
		read, err := f.c.methodRuntimeAuthRead(context.Background(), map[string]any{
			"provider": "codex", "identity_material": f.command,
		})
		if err != nil || mapParam(read, "auth")["issue"] != "login_failed" {
			t.Fatalf("ambiguous supersession read = %#v, %v", read, err)
		}
		assertTerminal(t, f)
	})

	t.Run("account update notification", func(t *testing.T) {
		f := setup(t)
		f.manager.handleNotification(f.runtime, map[string]any{
			"method": "account/updated",
			"params": map[string]any{"authMode": "chatgpt"},
		})
		waitForRuntimeAuthCondition(t, "notification supersession terminal publication", func() bool {
			auth := mapParam(runtimeAuthTestObservation(f.c, f.command), "auth")
			return f.manager.attempt(runtimeProbeTarget{
				provider: "codex", identityMaterial: f.command,
			}.key()) == nil && auth["status"] == "error" && auth["issue"] == "login_failed"
		}, func() string {
			return fmt.Sprintf("runtime=%#v", runtimeAuthTestObservation(f.c, f.command))
		})
		assertTerminal(t, f)
	})
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
		waitForRuntimeAuthCondition(t, "external sign-in", func() bool {
			runtime := runtimeAuthTestObservation(c, command)
			return runtime["ready"] == true && runtime["status"] == "available" &&
				mapParam(runtime, "auth")["status"] == "authenticated"
		}, func() string { return fmt.Sprintf("%#v", runtimeAuthTestObservation(c, command)) })
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
		waitForRuntimeAuthCondition(t, "external sign-out", func() bool {
			runtime := runtimeAuthTestObservation(c, command)
			return runtime["ready"] == false && runtime["status"] == "unavailable" &&
				runtime["readiness_issue"] == "authentication_required" &&
				mapParam(runtime, "auth")["status"] == "unauthenticated"
		}, func() string { return fmt.Sprintf("%#v", runtimeAuthTestObservation(c, command)) })
	})
}

func TestRuntimeAuthSaturationDoesNotExhaustOrdinaryRequestAdmission(t *testing.T) {
	c, err := newConnector(config{name: "auth-admission", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeExternalRuntimes)
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
	waitForRuntimeAuthCondition(t, "fail-fast auth requests to release shared admission", func() bool {
		return len(c.requestSlots) == 0
	}, func() string { return fmt.Sprintf("request_slots=%d", len(c.requestSlots)) })

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
	t.Cleanup(c.closeExternalRuntimes)
	if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
		t.Fatalf("initial runtime inventory: %v", err)
	}
	return c, command, logPath
}

func runtimeOperationTestAuthority(c *connector) func(context.Context, message) error {
	c.setComputeRuntimeExecutionTarget(map[string]any{
		"runtime_instance_id":      defaultString(c.cfg.computeRuntimeInstanceID, "runtime"),
		"runtime_generation":       c.cfg.computeRuntimeGeneration,
		"runtime_connection_epoch": defaultString(c.cfg.computeRuntimeEpoch, "epoch"),
		"workload_id":              defaultString(c.cfg.computeRuntimeWorkloadID, "workload"),
		"workload_generation":      c.cfg.computeRuntimeGeneration,
		"allocation_id":            "allocation",
		"allocation_generation":    1,
		"container_id":             "container",
		"container_instance_id":    "container-instance",
	})
	return func(_ context.Context, request message) error {
		if request.Method != "runtime_execution" {
			return nil
		}
		target := mapParam(request.Params, "target")
		result := map[string]any{
			"execution_id":          stringParam(request.Params, "execution_id"),
			"container_instance_id": stringParam(target, "container_instance_id"),
		}
		switch stringParam(request.Params, "action") {
		case "acquire":
			result["acquired"] = true
		case "release":
			result["released"] = true
		default:
			return fmt.Errorf("unexpected runtime execution action %q", stringParam(request.Params, "action"))
		}
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: result})
		return nil
	}
}

func runtimeAuthTestObservation(c *connector, command string) map[string]any {
	for _, runtime := range c.runtimeInventory.snapshot() {
		if stringParam(runtime, "provider") == "codex" && stringParam(runtime, "identity_material") == command {
			return runtime
		}
	}
	return map[string]any{}
}
