package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func harnessFallbackForTest(t *testing.T, provider string) (string, string) {
	t.Helper()
	isolateHostRuntimeCommands(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	log := filepath.Join(t.TempDir(), "native.log")
	var command string
	switch provider {
	case "codex":
		command = fakeCodexCommand(t, log, nil)
	case "claude":
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", log)
		command = fakeClaudeRuntimeCommand(t)
	case "pi":
		t.Setenv("SALIX_TEST_FAKE_PI_LOG", log)
		command = fakePortableRuntimeCommand(t, "pi")
	}
	original := imageHarnessCommand
	imageHarnessCommand = func(kind string) string {
		if kind == provider {
			return command
		}
		return original(kind)
	}
	t.Cleanup(func() { imageHarnessCommand = original })
	return command, log
}

func harnessConnectorForTest(t *testing.T) *connector {
	t.Helper()
	c, err := newConnector(config{name: "harness-startup-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		c.closeExternalRuntimes()
		if c.bridgeServer != nil {
			_ = c.bridgeServer.Shutdown(context.Background())
		}
		c.externalRuntimeState.close()
	})
	return c
}

func TestHarnessStartupFallbackPreservesInputAndIdentity(t *testing.T) {
	for _, provider := range []string{"codex", "claude", "pi"} {
		t.Run(provider, func(t *testing.T) {
			_, log := harnessFallbackForTest(t, provider)
			broken := filepath.Join(t.TempDir(), provider)
			if err := os.WriteFile(broken, []byte("#!/bin/sh\necho 'stream-json unsupported' >&2\nexit 42\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			c := harnessConnectorForTest(t)
			input := externalRuntimeInput{command: broken, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "one business input"}}}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, execution, err := c.runtimeImplementations[provider].Send(ctx, input)
			if err != nil {
				t.Fatalf("fallback Send: %v", err)
			}
			if execution != input.executionID {
				t.Fatalf("changed execution: %q", execution)
			}
			data, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Count(string(data), "one business input") != 1 {
				t.Fatalf("business input was not sent exactly once: %s", data)
			}
			c.externalRuntimeState.mu.Lock()
			var identity externalRuntimeSessionIdentity
			for _, current := range c.externalRuntimeState.identities {
				if current.Provider == provider && current.SessionID == input.sessionID {
					identity = current
				}
			}
			c.externalRuntimeState.mu.Unlock()
			if identity.Command != broken {
				t.Fatalf("changed durable command identity: %#v", identity)
			}
		})
	}
}

func TestHarnessStartupKeepsUsableUserCommand(t *testing.T) {
	for _, provider := range []string{"codex", "claude", "pi"} {
		t.Run(provider, func(t *testing.T) {
			user, log := harnessFallbackForTest(t, provider)
			marker := filepath.Join(t.TempDir(), "unexpected-default")
			original := imageHarnessCommand
			fallback := filepath.Join(t.TempDir(), provider)
			if err := os.WriteFile(fallback, []byte("#!/bin/sh\necho called > "+shellQuote(marker)+"\nexit 42\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			imageHarnessCommand = func(string) string { return fallback }
			defer func() { imageHarnessCommand = original }()
			c := harnessConnectorForTest(t)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			input := externalRuntimeInput{command: user, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "use user command"}}}
			if _, _, err := c.runtimeImplementations[provider].Send(ctx, input); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("usable user command started default")
			}
			data, _ := os.ReadFile(log)
			if strings.Count(string(data), "use user command") != 1 {
				t.Fatalf("user command did not receive one input: %s", data)
			}
		})
	}
}

func TestCodexHarnessFallbackSerializesAuthAndSessionStartup(t *testing.T) {
	_, log := harnessFallbackForTest(t, "codex")
	closed := filepath.Join(t.TempDir(), "close-initialize")
	if err := os.WriteFile(closed, []byte("close\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	first := fakeCodexCommand(t, filepath.Join(t.TempDir(), "first.log"), map[string]string{"SALIX_TEST_FAKE_CODEX_CLOSE_INITIALIZE_ONCE": closed})
	c := harnessConnectorForTest(t)
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	target := runtimeProbeTarget{provider: "codex", identityMaterial: first}
	unlock := c.runtimeAuthCoordinator().lockTarget(target.key())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	results := make(chan *codexRuntime, 2)
	failures := make(chan error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		native, err := implementation.ensureTargetRuntime(ctx, target)
		results <- native
		failures <- err
	}()
	go func() {
		defer wg.Done()
		native, err := implementation.ensureRuntime(ctx, externalRuntimeInput{command: first}, &codexRuntimeSession{})
		results <- native
		failures <- err
	}()
	wg.Wait()
	unlock()
	for n := 0; n < 2; n++ {
		if err := <-failures; err != nil {
			t.Fatal(err)
		}
	}
	a, b := <-results, <-results
	if a != b || a.command != first {
		t.Fatal("concurrent startup changed runtime ownership")
	}
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "start\n") != 1 {
		t.Fatalf("default started more than once: %s", data)
	}
	if _, err := a.rpc(ctx, "account/read", nil, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestHarnessStartupDoesNotRetryAuthenticationOrNativeRejection(t *testing.T) {
	for _, provider := range []string{"codex", "claude", "pi"} {
		t.Run(provider, func(t *testing.T) {
			_, fallbackLog := harnessFallbackForTest(t, provider)
			command := filepath.Join(t.TempDir(), provider)
			switch provider {
			case "codex":
				marker := filepath.Join(t.TempDir(), "reject-initialize")
				if err := os.WriteFile(marker, []byte("reject\n"), 0o600); err != nil {
					t.Fatal(err)
				}
				command = fakeCodexCommand(t, filepath.Join(t.TempDir(), "user.log"), map[string]string{"SALIX_TEST_FAKE_CODEX_FAIL_INITIALIZE_ONCE": marker})
			case "claude":
				if err := os.WriteFile(command, []byte("#!/bin/sh\necho 'authentication required: please login' >&2\nexit 1\n"), 0o755); err != nil {
					t.Fatal(err)
				}
			case "pi":
				script := "#!/bin/sh\nread request\necho '{\"id\":\"salix-1\",\"type\":\"response\",\"success\":false,\"error\":\"authentication required\"}'\ncat > /dev/null\n"
				if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			c := harnessConnectorForTest(t)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			input := externalRuntimeInput{command: command, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "must not dispatch"}}}
			if _, _, err := c.runtimeImplementations[provider].Send(ctx, input); err == nil {
				t.Fatal("accepted a rejected startup")
			}
			if data, err := os.ReadFile(fallbackLog); err == nil {
				t.Fatalf("authentication/rejection started default: %s", data)
			}
		})
	}
}

func TestHarnessStartupDoesNotRetryUnknownBusinessSend(t *testing.T) {
	_, fallbackLog := harnessFallbackForTest(t, "claude")
	userLog := filepath.Join(t.TempDir(), "user.log")
	// The user CLI completes initialization, then closes stdout after input.
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", userLog)
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_PROTOCOL", "stdout_closed")
	user := fakeClaudeRuntimeCommand(t)
	c := harnessConnectorForTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	input := externalRuntimeInput{command: user, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "unknown business send"}}}
	if _, _, err := c.runtimeImplementations["claude"].Send(ctx, input); err == nil {
		t.Fatal("unknown send succeeded")
	}
	if data, err := os.ReadFile(fallbackLog); err == nil {
		t.Fatalf("unknown send started default: %s", data)
	}
	data, _ := os.ReadFile(userLog)
	if strings.Count(string(data), "unknown business send") != 1 {
		t.Fatalf("business send was lost or retried: %s", data)
	}
	if !c.externalRuntimeState.watched("claude", input.sessionID) {
		t.Fatal("unknown send lost its recovery obligation")
	}
}

func TestHarnessStartupRefusesAuthAndConfigExit(t *testing.T) {
	for _, provider := range []string{"codex", "claude", "pi"} {
		for _, reason := range []string{"authentication required: please login", "invalid model configuration"} {
			t.Run(provider+"/"+reason, func(t *testing.T) {
				_, log := harnessFallbackForTest(t, provider)
				command := filepath.Join(t.TempDir(), provider)
				if err := os.WriteFile(command, []byte("#!/bin/sh\necho "+shellQuote(reason)+" >&2\nexit 42\n"), 0o755); err != nil {
					t.Fatal(err)
				}
				c := harnessConnectorForTest(t)
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				input := externalRuntimeInput{command: command, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "must retain refusal"}}}
				if _, _, err := c.runtimeImplementations[provider].Send(ctx, input); err == nil {
					t.Fatal("startup refusal was hidden by fallback")
				}
				if data, err := os.ReadFile(log); err == nil {
					t.Fatalf("startup refusal launched default: %s", data)
				}
			})
		}
	}
}

func TestHarnessStartupCandidateCannotPublishBusinessEvents(t *testing.T) {
	for _, tc := range []struct {
		provider, output string
		rejected         bool
	}{
		{"claude", `{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["startup refusal"]}`, true},
		{"claude", `{"type":"system","session_id":"00000000-0000-4000-8000-000000000099"}`, true},
		{"pi", `{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"phantom-startup"}]}}`, false},
		{"pi", `{"type":"error","error":"startup refusal"}`, true},
	} {
		t.Run(tc.provider+"/"+tc.output, func(t *testing.T) {
			_, fallbackLog := harnessFallbackForTest(t, tc.provider)
			command := filepath.Join(t.TempDir(), tc.provider)
			if err := os.WriteFile(command, []byte("#!/bin/sh\necho "+shellQuote(tc.output)+"\nexit 42\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			c := harnessConnectorForTest(t)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			input := externalRuntimeInput{command: command, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "real business input"}}}
			_, _, err := c.runtimeImplementations[tc.provider].Send(ctx, input)
			if tc.rejected && err == nil {
				t.Fatal("native startup refusal launched default")
			}
			if !tc.rejected && err != nil {
				t.Fatal(err)
			}
			for _, event := range runtimeEventPayloads(t, c) {
				if event["work_state"] == "failed" || strings.Contains(fmt.Sprint(event), "phantom-startup") {
					t.Fatalf("startup candidate polluted durable output: %#v", event)
				}
			}
			if tc.rejected {
				if data, err := os.ReadFile(fallbackLog); err == nil {
					t.Fatalf("native startup refusal reached default: %s", data)
				}
			}
		})
	}
}

func TestPiHarnessFallbackStopsFailedCandidateChildren(t *testing.T) {
	_, _ = harnessFallbackForTest(t, "pi")
	childFile := filepath.Join(t.TempDir(), "child.pid")
	command := filepath.Join(t.TempDir(), "pi")
	script := "#!/bin/sh\nsleep 300 &\necho $! > " + shellQuote(childFile) + "\nread request\necho '{\"id\":\"salix-1\",\"type\":\"response\",\"success\":true,\"data\":{}}'\ncat > /dev/null\n"
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c := harnessConnectorForTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	input := externalRuntimeInput{command: command, workspace: c.root, sessionID: "session-one", token: "token-one", dispatchID: "dispatch-one", executionID: "execution-one", messages: []map[string]any{{"role": "user", "content": "after failed candidate exits"}}}
	_, _, sendErr := c.runtimeImplementations["pi"].Send(ctx, input)
	data, err := os.ReadFile(childFile)
	if err != nil {
		t.Fatal(err)
	}
	child, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Kill(child, syscall.SIGKILL)
	if sendErr != nil {
		t.Fatal(sendErr)
	}
	deadline := time.Now().Add(time.Second)
	for syscall.Kill(child, 0) == nil && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if syscall.Kill(child, 0) == nil {
		t.Fatal("default started while a failed candidate child remained alive")
	}
}

func TestCodexRestoredNormalExitBeforeListenStopsRecovery(t *testing.T) {
	isolateHostRuntimeCommands(t)
	t.Setenv("HOME", t.TempDir())
	marker := filepath.Join(t.TempDir(), "normal-exit")
	if err := os.WriteFile(marker, []byte("armed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "codex.log")
	command := fakeCodexCommand(t, log, map[string]string{"SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_LISTEN_ONCE": marker})
	c := harnessConnectorForTest(t)
	i := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	input := externalRuntimeInput{command: command, workspace: c.root, sessionID: "restored-session", token: "restored-token", dispatchID: "restored-dispatch", executionID: "restored-execution", payload: map[string]any{"thread_id": "restored-thread"}}
	if err := c.watchExternalRuntime("codex", input); err != nil {
		t.Fatal(err)
	}
	if err := i.Restore(input); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = i.Check(ctx, input.sessionID)
	if c.externalRuntimeState.watched("codex", input.sessionID) {
		t.Fatal("normal exit before listen retained a recovery obligation")
	}
	_ = i.Check(ctx, input.sessionID)
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "start\n") != 1 {
		t.Fatalf("normal exit restarted app-server: %s", data)
	}
	c.bridgeMu.Lock()
	_, routed := c.runtimeRoutes["restored-thread"]
	c.bridgeMu.Unlock()
	if routed {
		t.Fatal("normally stopped restored thread retained its route")
	}
}

func TestCodexFreshNormalExitBeforeListenPreservesClaim(t *testing.T) {
	isolateHostRuntimeCommands(t)
	t.Setenv("HOME", t.TempDir())
	marker := filepath.Join(t.TempDir(), "normal-exit")
	if err := os.WriteFile(marker, []byte("armed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "codex.log"), map[string]string{"SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_LISTEN_ONCE": marker})
	c := harnessConnectorForTest(t)
	batch := testRuntimeInputBatch("codex", "fresh-session", "fresh-dispatch", "pending-input")
	batch.Session.Command, batch.Session.Workspace = command, c.root
	persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	var err error
	input, err = c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := c.runtimeImplementations["codex"].Send(ctx, input); err == nil {
		t.Fatal("normal startup exit admitted fresh input")
	}
	if !c.externalRuntimeState.watched("codex", input.sessionID) {
		t.Fatal("normal startup exit discarded an unstarted claim")
	}
	_, _, pending, _ := c.externalRuntimeState.healthCounts()
	if pending != 1 {
		t.Fatalf("normal startup exit discarded pending input: %d", pending)
	}
}
