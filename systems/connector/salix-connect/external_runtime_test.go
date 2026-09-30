package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestExternalRuntimeInputRequiresDispatchID(t *testing.T) {
	_, _, err := parseExternalRuntimeInput(map[string]any{
		"kind":                     "external",
		"provider":                 "codex",
		"session_id":               "session-1",
		"runtime_capability_token": "token-1",
		"input_messages":           []any{map[string]any{"role": "user", "content": "hello"}},
	})
	if err == nil {
		t.Fatal("expected missing dispatch_id to be rejected")
	}
}

func TestExternalRuntimeInputDoesNotAcceptServerNativeState(t *testing.T) {
	_, input, err := parseExternalRuntimeInput(map[string]any{
		"kind":                     "external",
		"provider":                 "pi",
		"session_id":               "session-1",
		"dispatch_id":              "batch-message-1",
		"runtime_capability_token": "token-1",
		"runtime_payload":          map[string]any{"session_id": "injected-native-session"},
		"input_messages":           []any{map[string]any{"role": "user", "content": "hello"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(input.payload) != 0 {
		t.Fatalf("Server influenced Connector-owned native state: %#v", input.payload)
	}
}

func TestRecoveryRecordPreservesRuntimeFence(t *testing.T) {
	input := externalRuntimeInput{
		sessionID:   "session-1",
		dispatchID:  "dispatch-1",
		executionID: "execution-1",
		token:       "token-1",
		command:     "/usr/local/bin/pi",
		workspace:   "/tmp/workspace",
		payload:     map[string]any{"session_id": "native-1"},
	}

	restored := externalRuntimeRecoveryRecordFromInput("pi", input).input()
	if restored.dispatchID != input.dispatchID || restored.executionID != input.executionID {
		t.Fatalf("recovery lost runtime fence: %#v", restored)
	}
}

func TestAttachRuntimeIdentityDoesNotClaimRunningWithoutLifecycleEvidence(t *testing.T) {
	event := attachRuntimeIdentity(
		standardRuntimeEvent("codex", "status", "dispatch.accepted"),
		"dispatch-1",
		"execution-1",
		"",
	)
	if event["dispatch_id"] != "dispatch-1" || event["execution_id"] != "execution-1" {
		t.Fatalf("unexpected identity: %#v", event)
	}
	if _, ok := event["work_state"]; ok {
		t.Fatalf("acceptance must not claim work_state: %#v", event)
	}
}

func TestCodexLifecycleTracksNativeTurn(t *testing.T) {
	session := &codexRuntimeSession{
		sessionID:   "session-1",
		dispatchID:  "dispatch-1",
		executionID: "execution-1",
		workState:   "starting",
	}
	implementation := &codexRuntimeImplementation{
		connector: &connector{},
		sessions:  map[string]*codexRuntimeSession{"session-1": session},
		threads:   map[string]string{"thread-1": "session-1"},
	}

	implementation.forwardEvent(codexTurnEvent("turn/started", "thread-1", "turn-1", "inProgress"))
	if session.workState != "running" || session.activeTurnID != "turn-1" {
		t.Fatalf("turn/started did not establish running: %#v", session)
	}

	implementation.forwardEvent(codexTurnEvent("turn/completed", "thread-1", "turn-1", "completed"))
	if session.workState != "settled" || session.activeTurnID != "" {
		t.Fatalf("turn/completed did not settle work: %#v", session)
	}
}

func TestCodexQuotaErrorIsAttachedToMatchingTerminalFailure(t *testing.T) {
	messages := make(chan message, 4)
	connector := newEventTestConnector(t, t.TempDir())
	defer connector.externalRuntimeState.close()
	deactivate := activateRuntimeTransportForTest(connector, func(item message) error {
		messages <- item
		return nil
	})
	defer deactivate()

	session := &codexRuntimeSession{
		sessionID:   "session-1",
		token:       "token-1",
		dispatchID:  "dispatch-1",
		executionID: "execution-1",
		workState:   "starting",
	}
	implementation := &codexRuntimeImplementation{
		connector: connector,
		sessions:  map[string]*codexRuntimeSession{"session-1": session},
		threads:   map[string]string{"thread-1": "session-1"},
	}

	implementation.forwardEvent(codexTurnEvent("turn/started", "thread-1", "turn-1", "inProgress"))
	implementation.forwardEvent(map[string]any{
		"method": "error",
		"params": map[string]any{
			"threadId": "thread-1",
			"turnId":   "turn-1",
			"error": map[string]any{
				"code":    "usage_limit_reached",
				"message": "You have no credits left",
			},
		},
	})
	implementation.forwardEvent(codexTurnEvent("turn/completed", "thread-1", "turn-1", "failed"))

	var terminal map[string]any
	received := 0
	for received < 3 {
		select {
		case request := <-messages:
			items := eventRequestItems(t, request)
			for _, item := range items {
				event := mapParam(item.Params, "event")
				if event["work_state"] == "failed" {
					terminal = event
				}
			}
			received += len(items)
			acknowledgeEventRequest(t, connector, request)
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for normalized Codex events")
		}
	}
	if terminal["issue"] != "quota_exhausted" {
		t.Fatalf("terminal issue = %#v, want quota_exhausted: %#v", terminal["issue"], terminal)
	}
	if terminal["message"] != "Codex account usage quota is exhausted." {
		t.Fatalf("terminal message = %#v", terminal["message"])
	}
}

func TestRuntimeFailureNormalizationIsStableAndDoesNotExposeRawDetail(t *testing.T) {
	for _, tc := range []struct {
		name, code, detail, issue, message string
	}{
		{"rate limited", "rate_limit_exceeded", "retry after 12", "rate_limited", "Codex is temporarily rate limited."},
		{"model unavailable", "model_not_found", "private-model", "model_unavailable", "The configured Codex model is unavailable."},
		{"fixed quota text fixture", "", "You have no credits left", "quota_exhausted", "Codex account usage quota is exhausted."},
		{"Codex current usage limit text", "", "You've hit your usage limit. Visit the account settings to purchase more credits or try again later.", "quota_exhausted", "Codex account usage quota is exhausted."},
		{"unknown secret-bearing error", "provider_error", "Authorization: Bearer secret\n/private/home", "runtime_failed", "Codex runtime execution failed."},
		{"owned abandonment reason", "", externalRuntimeRecoveryAbandonReason, "recovery_exhausted", "Codex session recovery attempts were exhausted."},
	} {
		t.Run(tc.name, func(t *testing.T) {
			issue, message := normalizeRuntimeFailure("codex", tc.code, tc.detail)
			if issue != tc.issue || message != tc.message {
				t.Fatalf("detail = %q/%q, want %q/%q", issue, message, tc.issue, tc.message)
			}
			if len(message) > 300 || strings.Contains(message, "secret") || strings.Contains(message, "/private/home") || strings.ContainsAny(message, "\r\n") {
				t.Fatalf("unsafe normalized message: %q", message)
			}
		})
	}

	event := attachRuntimeIdentity(map[string]any{
		"provider": "codex", "type": "status", "issue": "quota_exhausted",
		"message": "Authorization: Bearer secret", "state": "failed",
	}, "dispatch", "execution", "failed")
	if event["message"] != "Codex account usage quota is exhausted." {
		t.Fatalf("preclassified terminal trusted raw message: %#v", event)
	}
}

func TestWorkspaceReadinessMessageClassifiesSafeOwnerFailures(t *testing.T) {
	t.Setenv("HOME", "/safe-home")
	for _, tc := range []struct {
		err  error
		want string
	}{
		{os.ErrPermission, "The external runtime workspace is not writable by the Connector."},
		{syscall.ENOSPC, "The external runtime workspace cannot be prepared because the device has no free disk space."},
		{errors.New("mkdir /private/home: provider token=secret"), "The external runtime workspace could not be prepared."},
	} {
		if got := externalRuntimeWorkspaceReadinessMessage(tc.err); got != tc.want {
			t.Fatalf("workspace message = %q, want %q", got, tc.want)
		}
	}
}

func TestCodexLateCompletedTurnKeepsItsOriginalFence(t *testing.T) {
	session := &codexRuntimeSession{
		sessionID:                "session-1",
		dispatchID:               "dispatch-new",
		executionID:              "execution-new",
		activeTurnID:             "turn-new",
		lastCompletedTurnID:      "turn-old",
		lastCompletedDispatchID:  "dispatch-old",
		lastCompletedExecutionID: "execution-old",
		workState:                "running",
	}
	messages := make(chan message, 1)
	connector := newEventTestConnector(t, t.TempDir())
	defer connector.externalRuntimeState.close()
	deactivate := activateRuntimeTransportForTest(connector, func(item message) error {
		messages <- item
		return nil
	})
	defer deactivate()
	implementation := &codexRuntimeImplementation{
		connector: connector,
		sessions:  map[string]*codexRuntimeSession{"session-1": session},
		threads:   map[string]string{"thread-1": "session-1"},
	}
	session.token = "token-1"

	implementation.forwardEvent(codexTurnEvent("turn/completed", "thread-1", "turn-old", "completed"))

	if session.workState != "running" || session.activeTurnID != "turn-new" {
		t.Fatalf("late old turn mutated current lifecycle: %#v", session)
	}
	select {
	case request := <-messages:
		item := eventRequestItems(t, request)[0]
		event := mapParam(item.Params, "event")
		if event["dispatch_id"] != "dispatch-old" || event["execution_id"] != "execution-old" || event["work_state"] != nil {
			t.Fatalf("late old turn used current fence: %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("late old turn event was not forwarded")
	}
}

func TestProviderContentDoesNotClaimNativeRunning(t *testing.T) {
	pi := &piRuntimeSession{dispatchID: "dispatch-1", executionID: "execution-1", workState: "starting"}
	_, _, piState := pi.observeEvent("message", "message_end")
	if piState != "" || pi.workState != "starting" {
		t.Fatalf("pi content claimed native running: %#v", pi)
	}

	kimi := &kimiRuntimeSession{dispatchID: "dispatch-1", executionID: "execution-1", workState: "starting"}
	_, _, kimiState := kimi.observeEvent(map[string]any{"type": "message", "name": "assistant.delta"})
	if kimiState != "" || kimi.workState != "starting" {
		t.Fatalf("kimi content claimed native running: %#v", kimi)
	}
}

func TestPiKilledProcessExitAfterSettlement(t *testing.T) {
	for _, state := range []string{"settled", "starting", "running"} {
		t.Run(state, func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			t.Cleanup(c.externalRuntimeState.close)
			session := &piRuntimeSession{
				connector: c, cmd: exec.Command("sleep", "60"), done: make(chan struct{}),
				token: "token-1", sessionID: "session-1", dispatchID: "dispatch-1",
				executionID: "execution-1", workState: state,
			}
			if err := session.cmd.Start(); err != nil {
				t.Fatal(err)
			}
			session.stop()
			session.wait()
			events := runtimeEventPayloads(t, c)
			if len(events) != 1 {
				t.Fatalf("events = %#v", events)
			}
			event := events[0]
			if event["dispatch_id"] != "dispatch-1" || event["execution_id"] != "execution-1" {
				t.Fatalf("lost execution identity: %#v", event)
			}
			if state == "settled" {
				if event["type"] != "status" || event["name"] != "runtime_stopped" || event["state"] != "stopped" || event["work_state"] != nil || event["issue"] != nil {
					t.Fatalf("settled exit became failure: %#v", event)
				}
				if session.workState != "settled" {
					t.Fatal("settled execution changed state")
				}
			} else if event["type"] != "error" || event["work_state"] != "failed" || event["issue"] != "runtime_failed" {
				t.Fatalf("active execution failure suppressed: %#v", event)
			}
		})
	}
}

func TestPiLifecycleReusesExecutionForSteer(t *testing.T) {
	session := &piRuntimeSession{}
	first, err := session.beginDispatch("dispatch-1", "token-1", "execution-1")
	if err != nil {
		t.Fatal(err)
	}
	_, _, workState := session.observeEvent("status", "agent_start")
	if workState != "running" {
		t.Fatalf("agent_start work_state = %q", workState)
	}
	second, err := session.beginDispatch("dispatch-2", "token-2", first)
	if err != nil {
		t.Fatal(err)
	}
	if second != first {
		t.Fatalf("active steer changed execution id: %q != %q", second, first)
	}
	if session.workState != "running" {
		t.Fatalf("active steer changed work state to %q", session.workState)
	}
	_, _, workState = session.observeEvent("status", "agent_settled")
	if workState != "settled" {
		t.Fatalf("agent_settled work_state = %q", workState)
	}
	if _, err := session.beginDispatch("dispatch-3", "token-3", first); err == nil {
		t.Fatal("settled Pi execution was reused for new work")
	}
	if third, err := session.beginDispatch("dispatch-3", "token-3", "execution-2"); err != nil || third == first {
		t.Fatalf("new Pi execution = %q, %v", third, err)
	}
}

func TestKimiLifecycleMapsTerminalFailure(t *testing.T) {
	session := &kimiRuntimeSession{}
	if _, err := session.beginDispatch("dispatch-1", "token-1", "execution-1"); err != nil {
		t.Fatal(err)
	}
	_, _, workState := session.observeEvent(map[string]any{"name": "turn.started"})
	if workState != "running" {
		t.Fatalf("turn.started work_state = %q", workState)
	}
	firstExecution := session.executionID
	secondExecution, err := session.beginDispatch("dispatch-2", "token-2", firstExecution)
	if err != nil {
		t.Fatal(err)
	}
	if secondExecution != firstExecution || session.workState != "running" {
		t.Fatalf("active Kimi steer changed lifecycle: %#v", session)
	}
	_, _, workState = session.observeEvent(map[string]any{"name": "turn.ended", "state": "failed"})
	if workState != "failed" {
		t.Fatalf("failed turn.ended work_state = %q", workState)
	}
	if _, err := session.beginDispatch("dispatch-3", "token-3", firstExecution); err == nil {
		t.Fatal("terminal Kimi execution was reused for new work")
	}
}

func TestKimiOperationUsesNativeIdentity(t *testing.T) {
	cases := []struct {
		name    string
		payload map[string]any
		want    string
	}{
		{"prompt", map[string]any{"promptId": "prompt-1"}, "prompt-1"},
		{"tool", map[string]any{"toolCallId": "tool-1"}, "tool-1"},
		{"subagent", map[string]any{"subagentId": "agent-1"}, "agent-1"},
		{"background", map[string]any{"info": map[string]any{"id": "task-1"}}, "task-1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := kimiOperationID(tc.payload); got != tc.want {
				t.Fatalf("kimiOperationID() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestSourceKimiHomeUsesExistingLegacyHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KIMI_CODE_HOME", "")
	legacy := filepath.Join(home, ".kimi")
	if err := os.Mkdir(legacy, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := sourceKimiHome("/usr/local/bin/kimi"); got != legacy {
		t.Fatalf("sourceKimiHome() = %q, want %q", got, legacy)
	}
}

func TestPortableRuntimeReadinessUsesNativeHandshake(t *testing.T) {
	for _, provider := range []string{"pi", "kimi"} {
		t.Run(provider, func(t *testing.T) {
			command := fakePortableRuntimeCommand(t, provider)
			if provider == "kimi" {
				t.Setenv("KIMI_CODE_HOME", t.TempDir())
			}

			runtimes := detectPortableRuntime(
				provider,
				"salix-test-"+provider+"-not-on-path",
				"test",
				[]string{"ws"},
				[]string{command},
			)
			if len(runtimes) != 1 {
				t.Fatalf("detected runtimes = %d, want 1", len(runtimes))
			}
			runtime := runtimes[0]
			for _, key := range []string{"version_detected", "auth_ready", "native_server_startable", "ready"} {
				want := provider != "pi" || (key != "auth_ready" && key != "ready")
				if runtime[key] != want {
					t.Fatalf("%s readiness %s = %#v, want %t", provider, key, runtime[key], want)
				}
			}
			if runtime["readiness_valid_until"].(int64) <= runtime["readiness_checked_at"].(int64) {
				t.Fatalf("%s readiness validity window is not positive: %#v", provider, runtime)
			}
		})
	}
}

func TestKimiReadinessRejectsNativeAuthSnapshotWithoutModel(t *testing.T) {
	t.Setenv("KIMI_CODE_HOME", t.TempDir())
	t.Setenv("SALIX_TEST_FAKE_KIMI_AUTH_READY", "0")
	command := fakePortableRuntimeCommand(t, "kimi")

	runtimes := detectPortableRuntime(
		"kimi",
		"salix-test-kimi-not-on-path",
		"test",
		[]string{"ws"},
		[]string{command},
	)
	if len(runtimes) != 1 {
		t.Fatalf("detected runtimes = %d, want 1", len(runtimes))
	}
	runtime := runtimes[0]
	if runtime["auth_ready"] != false || runtime["native_server_startable"] != true || runtime["ready"] != false {
		t.Fatalf("kimi readiness = %#v, want auth failure with a startable server", runtime)
	}
	if !strings.Contains(stringFromAny(runtime["last_error"]), "auth snapshot") {
		t.Fatalf("last_error = %#v, want auth snapshot diagnostic", runtime["last_error"])
	}
}

func TestPiReadinessRequiresProviderEvidence(t *testing.T) {
	for _, configured := range []bool{false, true} {
		t.Run(map[bool]string{false: "missing", true: "configured"}[configured], func(t *testing.T) {
			t.Setenv("SALIX_TEST_FAKE_PI_AUTH_READY", map[bool]string{false: "0", true: "1"}[configured])
			command := fakePortableRuntimeCommand(t, "pi")
			runtimes := detectPortableRuntime("pi", "salix-test-pi-not-on-path", "test", []string{"stdio"}, []string{command})
			if len(runtimes) != 1 {
				t.Fatalf("detected runtimes = %d, want 1", len(runtimes))
			}
			runtime := runtimes[0]
			if runtime["auth_ready"] != false || runtime["native_server_startable"] != true || runtime["ready"] != false {
				t.Fatalf("pi readiness = %#v, want no provider evidence with a startable RPC server", runtime)
			}
			issue, status := "authentication_required", "unauthenticated"
			if configured {
				issue, status = "verification_required", "configured"
			}
			if runtime["readiness_issue"] != issue || stringParam(mapParam(runtime, "auth"), "status") != status {
				t.Fatalf("pi configuration was misrepresented as provider evidence: %#v", runtime)
			}
		})
	}
}

func TestReconnectReplaysTerminalLifecycleObservation(t *testing.T) {
	messages := make(chan message, 1)
	connector := newEventTestConnector(t, t.TempDir())
	defer connector.externalRuntimeState.close()
	deactivate := activateRuntimeTransportForTest(connector, func(item message) error {
		messages <- item
		return nil
	})
	defer deactivate()

	session := &piRuntimeSession{
		connector:   connector,
		token:       "token-1",
		dispatchID:  "dispatch-1",
		executionID: "execution-1",
		workState:   "settled",
	}
	session.replayObservation()

	select {
	case request := <-messages:
		item := eventRequestItems(t, request)[0]
		event := mapParam(item.Params, "event")
		if event["work_state"] != "settled" {
			t.Fatalf("unexpected replay message: %#v", item)
		}
	case <-time.After(time.Second):
		t.Fatal("terminal lifecycle observation was not replayed")
	}
}

func fakePortableRuntimeCommand(t *testing.T, provider string) string {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	helper := map[string]string{"pi": "TestHelperPiRPC", "kimi": "TestHelperKimiServer"}[provider]
	environment := "SALIX_TEST_FAKE_" + strings.ToUpper(provider) + "=1"
	command := filepath.Join(t.TempDir(), provider)
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo " + provider + "-test; exit 0; fi\n" +
		environment + " exec " + shellQuote(executable) + " -test.run=^" + helper + "$ -- \"$@\"\n"
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return command
}

// Exercise the real process-exit owner, durable obligation and native Check
// continuation. Exit status alone cannot prove a turn completed or was stopped.
func TestPortableRuntimeZeroExitRecovery(t *testing.T) {
	for _, provider := range []string{"pi", "kimi", "claude"} {
		for _, state := range []string{"starting", "running", "settled", "stopped"} {
			t.Run(provider+"/"+state, func(t *testing.T) {
				logPath := filepath.Join(t.TempDir(), "native.log")
				t.Setenv("SALIX_TEST_FAKE_"+strings.ToUpper(provider)+"_LOG", logPath)
				var command string
				if provider == "claude" {
					command = fakeClaudeRuntimeCommand(t)
				} else {
					command = fakePortableRuntimeCommand(t, provider)
				}
				c, err := newConnector(config{name: "zero-exit", root: t.TempDir(), systemInfoInterval: 0})
				if err != nil {
					t.Fatal(err)
				}
				defer c.closeExternalRuntimes()
				defer func() {
					if c.bridgeServer != nil {
						_ = c.bridgeServer.Shutdown(context.Background())
					}
				}()
				nativeID, err := newClaudeSessionID()
				if err != nil {
					t.Fatal(err)
				}
				input := externalRuntimeInput{
					sessionID: "zero-session", dispatchID: "dispatch", executionID: "execution",
					token: "token", command: command, workspace: t.TempDir(),
					payload: map[string]any{"session_id": nativeID},
				}
				if err := c.watchExternalRuntime(provider, input); err != nil {
					t.Fatal(err)
				}
				implementation := c.runtimeImplementations[provider]
				if err := implementation.Restore(input); err != nil {
					t.Fatal(err)
				}
				cmd := exec.Command("sh", "-c", "exit 0")
				if err := cmd.Start(); err != nil {
					t.Fatal(err)
				}
				workState := state
				if state == "stopped" {
					workState = "running"
					c.forgetExternalRuntime(provider, input.sessionID)
				}
				switch i := implementation.(type) {
				case *piRuntimeImplementation:
					s := &piRuntimeSession{implementation: i, connector: c, cmd: cmd, done: make(chan struct{}),
						sessionID: input.sessionID, nativeID: nativeID, token: input.token,
						dispatchID: input.dispatchID, executionID: input.executionID, workState: workState, abandoned: state == "stopped"}
					i.sessionSlot(input.sessionID).session = s
					s.wait()
				case *kimiRuntimeImplementation:
					s := &kimiRuntimeSession{implementation: i, connector: c, cmd: cmd, done: make(chan struct{}),
						sessionID: input.sessionID, nativeID: nativeID, token: input.token,
						dispatchID: input.dispatchID, executionID: input.executionID, workState: workState, abandoned: state == "stopped"}
					i.sessionSlot(input.sessionID).session = s
					s.wait()
				case *claudeRuntimeImplementation:
					i.authGeneration.wait.Add(1)
					s := &claudeRuntimeSession{implementation: i, connector: c, cmd: cmd, done: make(chan struct{}),
						diagnostics:    &claudeDiagnosticBuffer{},
						authGeneration: i.authGeneration, sessionID: input.sessionID, nativeID: nativeID, token: input.token,
						dispatchID: input.dispatchID, executionID: input.executionID, workState: workState, abandoned: state == "stopped"}
					i.sessionSlot(input.sessionID).session = s
					s.wait()
				}
				wantRecovery := state == "starting" || state == "running"
				if got := c.externalRuntimeState.watched(provider, input.sessionID); got != wantRecovery {
					t.Fatalf("exit lost or invented recovery obligation: watched=%v want=%v", got, wantRecovery)
				}
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				if err := implementation.Check(ctx, input.sessionID); err != nil {
					t.Fatal(err)
				}
				if !wantRecovery {
					if _, err := os.Stat(logPath); !os.IsNotExist(err) {
						t.Fatal("stopped/settled runtime was restarted")
					}
					return
				}
				log, err := os.ReadFile(logPath)
				if err != nil {
					t.Fatal(err)
				}
				if !strings.Contains(string(log), nativeID) || !strings.Contains(string(log), externalRuntimeRecoveryMessage) {
					t.Fatalf("did not resume original native session with recovery prompt: %s", log)
				}
				found := false
				for _, event := range runtimeEventPayloads(t, c) {
					if event["name"] == "runtime_recovered" && event["dispatch_id"] == input.dispatchID && event["execution_id"] == input.executionID {
						found = true
					}
				}
				if !found {
					t.Fatal("native recovery did not commit exact execution receipt")
				}
			})
		}
	}
}

func codexTurnEvent(method, threadID, turnID, status string) map[string]any {
	return map[string]any{
		"method": method,
		"params": map[string]any{
			"threadId": threadID,
			"turn": map[string]any{
				"id":     turnID,
				"status": status,
			},
		},
	}
}

type scriptedRecoveryImplementation struct {
	mu              sync.Mutex
	provider        string
	connector       *connector
	failing         bool
	busy            bool
	checks          int
	abandonAttempts int
	abandoned       []string
}

func (f *scriptedRecoveryImplementation) Send(context.Context, externalRuntimeInput) (map[string]any, string, error) {
	return nil, "", errors.New("scripted implementation does not send")
}
func (f *scriptedRecoveryImplementation) Restore(externalRuntimeInput) error { return nil }

func (f *scriptedRecoveryImplementation) Check(context.Context, string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.checks++
	if f.failing {
		return errors.New("scripted recovery failure")
	}
	return nil
}

func (f *scriptedRecoveryImplementation) AbandonRecovery(record externalRuntimeRecoveryRecord, reason string) bool {
	f.mu.Lock()
	f.abandonAttempts++
	busy := f.busy
	if !busy {
		f.abandoned = append(f.abandoned, record.SessionID)
	}
	f.mu.Unlock()
	if busy {
		return false
	}
	return f.connector.abandonRuntimeObligation(record, reason)
}

func (f *scriptedRecoveryImplementation) ReplayObservations() {}
func (f *scriptedRecoveryImplementation) Close()              {}

func (f *scriptedRecoveryImplementation) set(update func(*scriptedRecoveryImplementation)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	update(f)
}

func (f *scriptedRecoveryImplementation) snapshot() (int, int, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.checks, f.abandonAttempts, append([]string(nil), f.abandoned...)
}

func testRecoveryObligationRecord(provider, sessionID, dispatchID, executionID string) externalRuntimeRecoveryRecord {
	return externalRuntimeRecoveryRecord{
		Provider: provider, SessionID: sessionID, DispatchID: dispatchID, ExecutionID: executionID,
		Token: "capability-claim", Command: "/usr/local/bin/" + provider,
		Workspace: "/tmp/workspace", Payload: map[string]any{"session_id": "native-1"},
	}
}

func newScriptedRecoveryConnector(t *testing.T, sessionID string) (*connector, *scriptedRecoveryImplementation, externalRuntimeRecoveryRecord) {
	t.Helper()
	c := newEventTestConnector(t, t.TempDir())
	t.Cleanup(c.externalRuntimeState.close)
	fake := &scriptedRecoveryImplementation{provider: "pi", connector: c, failing: true}
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": fake}
	record := testRecoveryObligationRecord("pi", sessionID, "dispatch-1", "execution-1")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	return c, fake, record
}

func runtimeEventPayloads(t *testing.T, c *connector) []map[string]any {
	t.Helper()
	var events []map[string]any
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeSessionEventsBucket).ForEach(func(_, raw []byte) error {
			var request map[string]any
			if err := json.Unmarshal(raw, &request); err != nil {
				return err
			}
			params, _ := request["params"].(map[string]any)
			if event, ok := params["event"].(map[string]any); ok {
				events = append(events, event)
			}
			return nil
		})
	}); err != nil {
		t.Fatal(err)
	}
	return events
}

// assertAbandonTerminalObservations enforces the abandonment notification
// contract: the final failed execution event in durable order carries the
// recovery_exhausted conclusion — earlier interruption-time events may
// legitimately carry runtime_failed, but nothing may supersede the
// abandonment, including echoes of its own deliberate kill — and the session
// reports runtime_stopped.
func assertAbandonTerminalObservations(t *testing.T, c *connector, provider string) {
	t.Helper()
	stopped := false
	var lastFailed map[string]any
	events := runtimeEventPayloads(t, c)
	for _, event := range events {
		if stringParam(event, "provider") != provider {
			continue
		}
		if stringParam(event, "type") == "status" && stringParam(event, "name") == "runtime_stopped" &&
			stringParam(event, "state") == "stopped" {
			stopped = true
		}
		if stringParam(event, "type") == "error" && stringParam(event, "work_state") == "failed" {
			lastFailed = event
		}
	}
	if !stopped || lastFailed == nil {
		t.Fatalf("terminal observations missing: stopped=%v lastFailed=%v events=%v", stopped, lastFailed, events)
	}
	if issue := stringParam(lastFailed, "issue"); issue != "recovery_exhausted" {
		t.Fatalf("final failed event superseded the abandonment conclusion: issue=%q event=%v", issue, lastFailed)
	}
	if message := stringParam(lastFailed, "message"); !strings.Contains(message, "session recovery attempts were exhausted") {
		t.Fatalf("abandonment failed event lost its canonical message: %q", message)
	}
}

// Round-2 regression: the recovery budget's own deliberate kill must not be
// echoed by the production session.wait exit path as a later runtime_failed
// for the same execution — the final observable issue stays
// recovery_exhausted on every abandonment path.
func TestAbandonRecoveryDeliberateKillDoesNotEchoRuntimeFailed(t *testing.T) {
	t.Run("pi", func(t *testing.T) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		implementation := newPiRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": implementation}
		record := testRecoveryObligationRecord("pi", "session-pi-kill", "dispatch-1", "execution-1")
		if err := c.externalRuntimeState.watch(record); err != nil {
			t.Fatal(err)
		}
		session := &piRuntimeSession{
			implementation: implementation,
			connector:      c,
			sessionID:      record.SessionID,
			token:          record.Token,
			cmd:            exec.Command("sleep", "60"),
			done:           make(chan struct{}),
			dispatchID:     record.DispatchID,
			executionID:    record.ExecutionID,
			workState:      "running",
		}
		if err := session.cmd.Start(); err != nil {
			t.Fatal(err)
		}
		go session.wait()
		slot := implementation.sessionSlot(record.SessionID)
		slot.mu.Lock()
		slot.session = session
		slot.mu.Unlock()
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy")
		}
		select {
		case <-session.done:
		case <-time.After(5 * time.Second):
			t.Fatal("production exit path did not finish")
		}
		for _, event := range runtimeEventPayloads(t, c) {
			if stringParam(event, "type") == "error" && stringParam(event, "issue") == "runtime_failed" {
				t.Fatalf("deliberate kill echoed as runtime_failed: %v", event)
			}
		}
		assertAbandonTerminalObservations(t, c, "pi")
	})

	t.Run("kimi", func(t *testing.T) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		implementation := newKimiRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"kimi": implementation}
		record := testRecoveryObligationRecord("kimi", "session-kimi-kill", "dispatch-1", "execution-1")
		if err := c.externalRuntimeState.watch(record); err != nil {
			t.Fatal(err)
		}
		session := &kimiRuntimeSession{
			implementation: implementation,
			connector:      c,
			sessionID:      record.SessionID,
			token:          record.Token,
			cmd:            exec.Command("sleep", "60"),
			done:           make(chan struct{}),
			dispatchID:     record.DispatchID,
			executionID:    record.ExecutionID,
			workState:      "running",
		}
		if err := session.cmd.Start(); err != nil {
			t.Fatal(err)
		}
		go session.wait()
		slot := implementation.sessionSlot(record.SessionID)
		slot.mu.Lock()
		slot.session = session
		slot.mu.Unlock()
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy")
		}
		select {
		case <-session.done:
		case <-time.After(5 * time.Second):
			t.Fatal("production exit path did not finish")
		}
		for _, event := range runtimeEventPayloads(t, c) {
			if stringParam(event, "type") == "error" && stringParam(event, "issue") == "runtime_failed" {
				t.Fatalf("deliberate kill echoed as runtime_failed: %v", event)
			}
		}
		assertAbandonTerminalObservations(t, c, "kimi")
	})
}

// interruptWatchedExecution replays the interruption-time exit event for a
// watched execution, moving its obligation into the interrupted phase — the
// phase real recovery work occupies after abnormal exits and connector
// restarts — with the earlier generic runtime_failed detail on record.
func interruptWatchedExecution(t *testing.T, c *connector, record externalRuntimeRecoveryRecord) {
	t.Helper()
	exitEvent := attachRuntimeIdentity(map[string]any{
		"type":       "error",
		"provider":   record.Provider,
		"message":    record.Provider + " process exited: boom",
		"created_at": int64(1),
	}, record.DispatchID, record.ExecutionID, "failed")
	if stringParam(exitEvent, "issue") != "runtime_failed" {
		t.Fatalf("interruption fixture must normalize to runtime_failed: %v", exitEvent)
	}
	if err := c.externalRuntimeState.enqueueExecutionEvent(
		record.Provider, record.SessionID, record.Token, exitEvent, externalRuntimeExecutionInterrupted,
	); err != nil {
		t.Fatal(err)
	}
}

// Regression for the interrupted-phase gap: after an abnormal exit or a
// connector restart the real obligation is interrupted and its earlier exit
// event was normalized as generic runtime_failed; abandonment must still
// forward the later recovery_exhausted conclusion.
func TestAbandonRecoveryInterruptedObligationStillAnnouncesRecoveryExhausted(t *testing.T) {
	t.Run("pi", func(t *testing.T) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		implementation := newPiRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": implementation}
		record := testRecoveryObligationRecord("pi", "session-pi-interrupted", "dispatch-1", "execution-1")
		if err := c.externalRuntimeState.watch(record); err != nil {
			t.Fatal(err)
		}
		if err := implementation.Restore(record.input()); err != nil {
			t.Fatal(err)
		}
		interruptWatchedExecution(t, c, record)
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle slot")
		}
		if c.externalRuntimeState.watched("pi", "session-pi-interrupted") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "pi")
	})

	t.Run("codex", func(t *testing.T) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		c.runtimeRoutes = map[string]string{}
		implementation := newCodexRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}
		record := testRecoveryObligationRecord("codex", "session-codex-interrupted", "dispatch-1", "execution-1")
		record.Payload = map[string]any{"thread_id": "thread-1"}
		if err := c.externalRuntimeState.watch(record); err != nil {
			t.Fatal(err)
		}
		if err := implementation.Restore(record.input()); err != nil {
			t.Fatal(err)
		}
		interruptWatchedExecution(t, c, record)
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle session")
		}
		if c.externalRuntimeState.watched("codex", "session-codex-interrupted") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "codex")
	})
}

func runRecoverySweeps(c *connector, passes int) {
	ctx := context.Background()
	for range passes {
		c.checkExternalRuntimes(ctx)
	}
}

// passesForFailedAttempts is the deterministic number of completed health
// passes from a fresh streak's first attempt up to and including failed
// attempt n, with the backoff schedule in between.
func passesForFailedAttempts(n int) int {
	total := 1
	for failures := 1; failures < n; failures++ {
		total += recoveryBackoffDelayTicks(failures)
	}
	return total
}

func TestExternalRuntimeRecoveryBackoffSchedule(t *testing.T) {
	c, fake, _ := newScriptedRecoveryConnector(t, "session-backoff")
	ctx := context.Background()
	// Attempts land on passes 1, 2, 4, 8, 14: delays double from one pass and
	// cap at externalRuntimeRecoveryBackoffCapTicks.
	wantByPass := map[int]int{1: 1, 2: 2, 3: 2, 4: 3, 7: 3, 8: 4, 13: 4, 14: 5}
	for pass := 1; pass <= 14; pass++ {
		c.checkExternalRuntimes(ctx)
		want, ok := wantByPass[pass]
		if !ok {
			continue
		}
		if checks, _, _ := fake.snapshot(); checks != want {
			t.Fatalf("pass %d: checks=%d want %d", pass, checks, want)
		}
	}
}

func TestExternalRuntimeRecoveryFailureBudgetAbandonsStuckSession(t *testing.T) {
	c, fake, _ := newScriptedRecoveryConnector(t, "session-budget")
	runRecoverySweeps(c, passesForFailedAttempts(externalRuntimeRecoveryFailureBudget)-1)
	if _, attempts, abandoned := fake.snapshot(); attempts != 0 || len(abandoned) != 0 {
		t.Fatalf("abandoned before the budget was exhausted: attempts=%d abandoned=%v", attempts, abandoned)
	}
	if !c.externalRuntimeState.watched("pi", "session-budget") {
		t.Fatal("obligation dropped before the budget was exhausted")
	}
	runRecoverySweeps(c, 1)
	if checks, _, abandoned := fake.snapshot(); len(abandoned) != 1 || abandoned[0] != "session-budget" ||
		checks != externalRuntimeRecoveryFailureBudget {
		t.Fatalf("expected abandonment on failed attempt %d, got checks=%d abandoned=%v",
			externalRuntimeRecoveryFailureBudget, checks, abandoned)
	}
	if c.externalRuntimeState.watched("pi", "session-budget") {
		t.Fatal("abandoned obligation is still watched")
	}
	checksBefore, _, _ := fake.snapshot()
	runRecoverySweeps(c, 1)
	checksAfter, _, abandoned := fake.snapshot()
	if checksAfter != checksBefore || len(abandoned) != 1 {
		t.Fatalf("abandoned session was checked again: checks %d -> %d abandoned=%v", checksBefore, checksAfter, abandoned)
	}
	if len(c.externalRuntimeRecoveryFailures) != 0 {
		t.Fatalf("stale failure streaks survive: %v", c.externalRuntimeRecoveryFailures)
	}
}

func TestExternalRuntimeV3RecoveryRequiresStableTimeBudget(t *testing.T) {
	c, fake, record := newScriptedRecoveryConnector(t, "session-time-budget")
	attachRuntimeExecutionTestTransport(t, c)
	promoteTestHostExecution(t, c, record.Provider, record.SessionID)
	failure := errors.New("native recovery unavailable")
	for range externalRuntimeRecoveryFailureBudget {
		c.applyRecoveryFailureBudget([]externalRuntimeRecoveryRecord{record}, []int{0}, []error{failure})
	}
	if _, attempts, abandoned := fake.snapshot(); attempts != 0 || len(abandoned) != 0 {
		t.Fatalf("v3 recovery ignored its 900-second budget: attempts=%d abandoned=%v", attempts, abandoned)
	}

	c.externalRuntimeState.mu.Lock()
	execution := c.externalRuntimeState.activeExecutions[record.key()]
	execution.RecoveryStartedAt = time.Now().Add(-externalRuntimeRecoveryBudget - time.Second).Unix()
	_, err := c.externalRuntimeState.storeActiveExecutionLocked(
		externalRuntimeIdentityFromRecovery(execution.Session), execution,
	)
	c.externalRuntimeState.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	fake.set(func(f *scriptedRecoveryImplementation) { f.busy = true })
	c.applyRecoveryFailureBudget([]externalRuntimeRecoveryRecord{record}, []int{0}, []error{failure})
	if _, attempts, abandoned := fake.snapshot(); attempts != 1 || len(abandoned) != 0 {
		t.Fatalf("expired budget did not become actionable: attempts=%d abandoned=%v", attempts, abandoned)
	}
	fake.set(func(f *scriptedRecoveryImplementation) { f.busy = false })
	c.applyRecoveryFailureBudget([]externalRuntimeRecoveryRecord{record}, []int{0}, []error{failure})
	if _, attempts, abandoned := fake.snapshot(); attempts != 2 || len(abandoned) != 1 {
		t.Fatalf("expired recovery obligation did not settle: attempts=%d abandoned=%v", attempts, abandoned)
	}
}

func TestExternalRuntimeRecoveryFailureBudgetResetsOnSuccess(t *testing.T) {
	c, fake, _ := newScriptedRecoveryConnector(t, "session-reset")
	runRecoverySweeps(c, passesForFailedAttempts(externalRuntimeRecoveryFailureBudget-1))
	fake.set(func(f *scriptedRecoveryImplementation) { f.failing = false })
	// The successful attempt arrives once the pending capped backoff elapses.
	runRecoverySweeps(c, externalRuntimeRecoveryBackoffCapTicks)
	if checks, _, _ := fake.snapshot(); checks != externalRuntimeRecoveryFailureBudget {
		t.Fatalf("expected the successful attempt within the capped backoff window, checks=%d", checks)
	}
	fake.set(func(f *scriptedRecoveryImplementation) { f.failing = true })
	// The reset must also clear the pending backoff: the next pass attempts
	// immediately, and a full fresh budget elapses before abandonment.
	checksBefore, _, _ := fake.snapshot()
	runRecoverySweeps(c, 1)
	if checks, _, _ := fake.snapshot(); checks != checksBefore+1 {
		t.Fatalf("streak reset kept a stale backoff: checks=%d want %d", checks, checksBefore+1)
	}
	runRecoverySweeps(c, passesForFailedAttempts(externalRuntimeRecoveryFailureBudget)-2)
	if _, attempts, _ := fake.snapshot(); attempts != 0 {
		t.Fatalf("a successful check did not reset the failure streak: attempts=%d", attempts)
	}
	runRecoverySweeps(c, 1)
	if _, _, abandoned := fake.snapshot(); len(abandoned) != 1 {
		t.Fatalf("expected abandonment after a fresh full budget, got %v", abandoned)
	}
}

func TestExternalRuntimeRecoveryFailureBudgetRetriesBusyAbandonment(t *testing.T) {
	c, fake, _ := newScriptedRecoveryConnector(t, "session-busy")
	fake.set(func(f *scriptedRecoveryImplementation) { f.busy = true })
	runRecoverySweeps(c, passesForFailedAttempts(externalRuntimeRecoveryFailureBudget))
	if _, attempts, abandoned := fake.snapshot(); attempts != 1 || len(abandoned) != 0 {
		t.Fatalf("busy abandonment mis-tracked: attempts=%d abandoned=%v", attempts, abandoned)
	}
	if !c.externalRuntimeState.watched("pi", "session-busy") {
		t.Fatal("busy session lost its obligation")
	}
	// Past the budget the retry keeps the capped backoff cadence.
	runRecoverySweeps(c, externalRuntimeRecoveryBackoffCapTicks-1)
	if _, attempts, _ := fake.snapshot(); attempts != 1 {
		t.Fatalf("busy abandonment retried inside the backoff window: attempts=%d", attempts)
	}
	runRecoverySweeps(c, 1)
	if _, attempts, _ := fake.snapshot(); attempts != 2 {
		t.Fatalf("busy abandonment was not retried after the backoff: attempts=%d", attempts)
	}
	fake.set(func(f *scriptedRecoveryImplementation) { f.busy = false })
	runRecoverySweeps(c, externalRuntimeRecoveryBackoffCapTicks)
	if _, _, abandoned := fake.snapshot(); len(abandoned) != 1 {
		t.Fatalf("expected abandonment once the session freed up, got %v", abandoned)
	}
	if c.externalRuntimeState.watched("pi", "session-busy") {
		t.Fatal("abandoned obligation is still watched")
	}
}

// A replacement execution for the same session key must earn its own full
// budget even when the key never leaves activeRecords between health passes,
// and must not inherit its predecessor's pending backoff.
func TestExternalRuntimeRecoveryFailureBudgetDoesNotInheritAcrossExecutions(t *testing.T) {
	c, fake, _ := newScriptedRecoveryConnector(t, "session-generations")
	runRecoverySweeps(c, passesForFailedAttempts(externalRuntimeRecoveryFailureBudget-1))
	c.externalRuntimeState.forget("pi", "session-generations")
	replacement := testRecoveryObligationRecord("pi", "session-generations", "dispatch-2", "execution-2")
	if err := c.externalRuntimeState.watch(replacement); err != nil {
		t.Fatal(err)
	}
	// The predecessor left a capped backoff pending; fresh work is due at once.
	checksBefore, _, _ := fake.snapshot()
	runRecoverySweeps(c, 1)
	if checks, attempts, abandoned := fake.snapshot(); checks != checksBefore+1 || attempts != 0 || len(abandoned) != 0 {
		t.Fatalf("replacement execution inherited predecessor state: checks=%d want %d attempts=%d abandoned=%v",
			checks, checksBefore+1, attempts, abandoned)
	}
	if !c.externalRuntimeState.watched("pi", "session-generations") {
		t.Fatal("replacement obligation was dropped")
	}
	runRecoverySweeps(c, passesForFailedAttempts(externalRuntimeRecoveryFailureBudget)-2)
	if _, attempts, abandoned := fake.snapshot(); attempts != 0 || len(abandoned) != 0 {
		t.Fatalf("replacement execution was abandoned before its own budget: attempts=%d abandoned=%v", attempts, abandoned)
	}
	runRecoverySweeps(c, 1)
	if _, _, abandoned := fake.snapshot(); len(abandoned) != 1 {
		t.Fatalf("replacement execution never reached its own budget: abandoned=%v", abandoned)
	}
}

func TestExternalRuntimeForgetExecutionRequiresMatchingFence(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	t.Cleanup(c.externalRuntimeState.close)
	record := testRecoveryObligationRecord("pi", "session-fence", "dispatch-1", "execution-1")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	stale := testRecoveryObligationRecord("pi", "session-fence", "dispatch-0", "execution-0")
	if phase, removed, err := c.externalRuntimeState.forgetExecution(stale); removed || err != nil {
		t.Fatalf("stale fence removed the obligation: phase=%q removed=%v err=%v", phase, removed, err)
	}
	if !c.externalRuntimeState.watched("pi", "session-fence") {
		t.Fatal("mismatched forgetExecution dropped the obligation")
	}
	phase, removed, err := c.externalRuntimeState.forgetExecution(record)
	if err != nil || !removed || phase != externalRuntimeExecutionStarting {
		t.Fatalf("matching fence was not removed: phase=%q removed=%v err=%v", phase, removed, err)
	}
	if c.externalRuntimeState.watched("pi", "session-fence") {
		t.Fatal("obligation survived a matching forgetExecution")
	}
}

func TestPiAbandonRecoveryAnnouncesTerminalObservations(t *testing.T) {
	newHarness := func(t *testing.T, sessionID string) (*connector, *piRuntimeImplementation, externalRuntimeRecoveryRecord) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		implementation := newPiRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": implementation}
		record := testRecoveryObligationRecord("pi", sessionID, "dispatch-1", "execution-1")
		if err := c.externalRuntimeState.watch(record); err != nil {
			t.Fatal(err)
		}
		if err := implementation.Restore(record.input()); err != nil {
			t.Fatal(err)
		}
		return c, implementation, record
	}

	t.Run("no live process", func(t *testing.T) {
		c, implementation, record := newHarness(t, "session-pi-restored")
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle slot")
		}
		if c.externalRuntimeState.watched("pi", "session-pi-restored") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "pi")
	})

	t.Run("live process", func(t *testing.T) {
		c, implementation, record := newHarness(t, "session-pi-live")
		session := &piRuntimeSession{cmd: exec.Command("sleep", "60"), done: make(chan struct{})}
		if err := session.cmd.Start(); err != nil {
			t.Fatal(err)
		}
		slot := implementation.sessionSlot("session-pi-live")
		slot.mu.Lock()
		slot.session = session
		slot.mu.Unlock()
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle slot")
		}
		slot.mu.Lock()
		detached := slot.session == nil
		slot.mu.Unlock()
		if !detached {
			t.Fatal("live session was not detached")
		}
		waited := make(chan error, 1)
		go func() { waited <- session.cmd.Wait() }()
		select {
		case <-waited:
		case <-time.After(5 * time.Second):
			t.Fatal("native process was not stopped")
		}
		if c.externalRuntimeState.watched("pi", "session-pi-live") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "pi")
	})
}

func TestKimiAbandonRecoveryAnnouncesTerminalObservations(t *testing.T) {
	newHarness := func(t *testing.T, sessionID string) (*connector, *kimiRuntimeImplementation, externalRuntimeRecoveryRecord) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		implementation := newKimiRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"kimi": implementation}
		record := testRecoveryObligationRecord("kimi", sessionID, "dispatch-1", "execution-1")
		if err := c.externalRuntimeState.watch(record); err != nil {
			t.Fatal(err)
		}
		if err := implementation.Restore(record.input()); err != nil {
			t.Fatal(err)
		}
		return c, implementation, record
	}

	t.Run("no live process", func(t *testing.T) {
		c, implementation, record := newHarness(t, "session-kimi-restored")
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle slot")
		}
		if c.externalRuntimeState.watched("kimi", "session-kimi-restored") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "kimi")
	})

	t.Run("live process", func(t *testing.T) {
		c, implementation, record := newHarness(t, "session-kimi-live")
		session := &kimiRuntimeSession{cmd: exec.Command("sleep", "60"), done: make(chan struct{})}
		if err := session.cmd.Start(); err != nil {
			t.Fatal(err)
		}
		slot := implementation.sessionSlot("session-kimi-live")
		slot.mu.Lock()
		slot.session = session
		slot.mu.Unlock()
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle slot")
		}
		waited := make(chan error, 1)
		go func() { waited <- session.cmd.Wait() }()
		select {
		case <-waited:
		case <-time.After(5 * time.Second):
			t.Fatal("native process was not stopped")
		}
		if c.externalRuntimeState.watched("kimi", "session-kimi-live") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "kimi")
	})
}

func TestCodexAbandonRecoveryClearsObligationAndAcceptsNewInput(t *testing.T) {
	newHarness := func(t *testing.T) (*connector, *codexRuntimeImplementation, externalRuntimeInput) {
		c := newEventTestConnector(t, t.TempDir())
		t.Cleanup(c.externalRuntimeState.close)
		c.runtimeRoutes = map[string]string{}
		implementation := newCodexRuntimeImplementation(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}
		input := externalRuntimeInput{
			sessionID: "session-codex", dispatchID: "dispatch-1", executionID: "execution-1",
			token: "capability-claim", command: "/usr/local/bin/codex", workspace: "/tmp/workspace",
			payload: map[string]any{"thread_id": "thread-1"},
		}
		if err := c.watchExternalRuntime("codex", input); err != nil {
			t.Fatal(err)
		}
		return c, implementation, input
	}

	t.Run("restored session", func(t *testing.T) {
		c, implementation, input := newHarness(t)
		if err := implementation.Restore(input); err != nil {
			t.Fatal(err)
		}
		record := externalRuntimeRecoveryRecordFromInput("codex", input)
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy for an idle session")
		}
		if c.externalRuntimeState.watched("codex", "session-codex") {
			t.Fatal("obligation survived abandonment")
		}
		resumable, recoverable, _, _ := c.externalRuntimeState.healthCounts()
		if resumable != 0 || recoverable != 0 {
			t.Fatalf("abandonment left durable state: resumable=%d recoverable=%d", resumable, recoverable)
		}
		assertAbandonTerminalObservations(t, c, "codex")
		batch := testRuntimeInputBatch("codex", "session-codex", "dispatch-2", "message-2")
		batch.Session.Command = "/usr/local/bin/codex"
		persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
		fresh := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
		if _, err := c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, fresh); err != nil {
			t.Fatalf("new input is still rejected after abandonment: %v", err)
		}
	})

	t.Run("no in-memory session", func(t *testing.T) {
		c, implementation, input := newHarness(t)
		record := externalRuntimeRecoveryRecordFromInput("codex", input)
		if !implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("abandonment reported busy without a session")
		}
		if c.externalRuntimeState.watched("codex", "session-codex") {
			t.Fatal("obligation survived abandonment")
		}
		assertAbandonTerminalObservations(t, c, "codex")
	})

	t.Run("stale fence is not abandoned", func(t *testing.T) {
		c, implementation, input := newHarness(t)
		if err := implementation.Restore(input); err != nil {
			t.Fatal(err)
		}
		stale := externalRuntimeRecoveryRecordFromInput("codex", input)
		stale.DispatchID, stale.ExecutionID = "dispatch-0", "execution-0"
		if !implementation.AbandonRecovery(stale, externalRuntimeRecoveryAbandonReason) {
			t.Fatal("stale abandonment should report done, not busy")
		}
		if !c.externalRuntimeState.watched("codex", "session-codex") {
			t.Fatal("stale fence abandoned the current execution")
		}
		if events := runtimeEventPayloads(t, c); len(events) != 0 {
			t.Fatalf("stale abandonment forwarded observations: %v", events)
		}
	})
}

func TestExternalRuntimeInputPreservesOriginalTimeAcrossQueuedDelivery(t *testing.T) {
	input := externalRuntimeInput{dispatchID: "batch-time", messages: []map[string]any{
		{"id": "message-1", "role": "user", "content": "yesterday?", "created_at": 1788998400,
			"input_time": map[string]any{"source_sent_at": "2026-09-09T23:59:00Z", "received_at": "2026-09-10T00:01:00Z", "timezone": "Etc/UTC"}},
		{"id": "message-2", "role": "user", "content": "unknown original time", "input_time": map[string]any{"source_sent_at": nil, "received_at": "2026-09-10T00:02:00Z"}},
	}}
	batch, err := input.agentBatchMessages(time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(batch[0]["content"].(string)), &envelope); err != nil {
		t.Fatal(err)
	}
	messages := envelope["messages"].([]any)
	first := messages[0].(map[string]any)
	if first["sent_at"] != "2026-09-09T23:59:00Z" {
		t.Fatalf("source date moved to delivery: %v", first)
	}
	if first["input_time"].(map[string]any)["received_at"] != "2026-09-10T00:01:00Z" {
		t.Fatal("arrival time lost")
	}
	if !strings.Contains(messages[1].(map[string]any)["sent_at"].(string), "Unknown") {
		t.Fatal("missing source time invented")
	}
	if !strings.Contains(input.text(), "2026-09-09T23:59:00Z") {
		t.Fatal("plain input lost source anchor")
	}
}

func TestRuntimeUsageResetSurvivesCanonicalizationWithoutRawDetails(t *testing.T) {
	for _, reset := range []any{int64(1789480200), float64(1789480200), nil, -1, "secret-token", float64(1e30)} {
		event := attachRuntimeIdentity(map[string]any{
			"provider": "claude", "type": "error", "name": "turn.ended",
			"issue": "quota_exhausted", "message": "secret-token",
			"usage_reset_at": reset, "created_at": int64(1789474000),
		}, "dispatch", "execution", "failed")
		for range 2 {
			canonical, err := canonicalExternalRuntimeEvent(event)
			if err != nil {
				t.Fatal(err)
			}
			message := stringParam(canonical, "message")
			if strings.Contains(message, "secret-token") || len(message) > 300 {
				t.Fatalf("unbounded/unsafe terminal detail: %#v", canonical)
			}
			wantReset := reset == int64(1789480200) || reset == float64(1789480200)
			if strings.Contains(message, "2026-09-15T13:50:00Z") != wantReset {
				t.Fatalf("reset mismatch for %#v: %#v", reset, canonical)
			}
			event = canonical
		}
	}
}
