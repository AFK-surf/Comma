package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDefaultClaudeCommandPathsIncludeHomebrewOnMacOS(t *testing.T) {
	home := filepath.Join(t.TempDir(), "connector-home")
	t.Setenv("HOME", home)

	paths := defaultClaudeCommandPaths()
	if len(paths) == 0 || paths[0] != filepath.Join(home, ".local", "bin", "claude") {
		t.Fatalf("default Claude command paths = %#v", paths)
	}

	if runtime.GOOS == "darwin" {
		for _, want := range []string{"/opt/homebrew/bin/claude", "/usr/local/bin/claude"} {
			found := false
			for _, path := range paths {
				if path == want {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("default Claude command paths omitted %q: %#v", want, paths)
			}
		}
		for _, want := range []string{"/opt/homebrew/bin/codex", "/usr/local/bin/codex"} {
			found := false
			for _, path := range defaultCodexAppBundleCommandPaths() {
				if path == want {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("default Codex command paths omitted %q: %#v", want, defaultCodexAppBundleCommandPaths())
			}
		}
	}

	path := runtimeCommandPath("/opt/homebrew/bin/claude", "/tmp/salix-cli")
	if !strings.Contains(path, "/tmp/salix-cli") || !strings.Contains(path, "/opt/homebrew/bin") {
		t.Fatalf("runtime command PATH = %q", path)
	}
}

func TestClaudeRuntimeReadinessUsesLocalAuthStatus(t *testing.T) {
	t.Run("authenticated", func(t *testing.T) {
		command := fakeClaudeRuntimeCommand(t)
		runtimes := detectPortableRuntime(
			"claude",
			"salix-test-claude-not-on-path",
			"agent-sdk-stream-json",
			[]string{"stdio"},
			[]string{command},
		)
		if len(runtimes) != 1 {
			t.Fatalf("detected runtimes = %d, want 1", len(runtimes))
		}
		for _, key := range []string{"version_detected", "auth_ready", "native_server_startable", "ready"} {
			if runtimes[0][key] != true {
				t.Fatalf("Claude readiness %s = %#v, want true: %#v", key, runtimes[0][key], runtimes[0])
			}
		}
	})

	t.Run("managed compute probe isolates host provider credentials", func(t *testing.T) {
		t.Setenv("ANTHROPIC_API_KEY", "host-api-key")
		t.Setenv("ANTHROPIC_AUTH_TOKEN", "host-auth-token")
		t.Setenv("ANTHROPIC_BASE_URL", "https://host.example")
		logPath := filepath.Join(t.TempDir(), "claude-probe.log")
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", logPath)
		runtime := portableRuntimeEntryWithClaudeIsolation("claude", fakeClaudeRuntimeCommand(t), "agent-sdk-stream-json", []string{"stdio"}, true)
		if runtime["ready"] != true {
			t.Fatalf("managed Claude readiness = %#v", runtime)
		}
		log, err := os.ReadFile(logPath)
		if err != nil || !strings.Contains(string(log), "provider_env=//") || strings.Contains(string(log), "host-api-key") {
			t.Fatalf("managed Claude probe inherited host provider credentials: %v\n%s", err, log)
		}
	})

	t.Run("signed out is bounded and secret free", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "signed_out")
		command := fakeClaudeRuntimeCommand(t)
		runtime := portableRuntimeEntry("claude", command, "agent-sdk-stream-json", []string{"stdio"})
		if runtime["auth_ready"] != false || runtime["native_server_startable"] != true || runtime["ready"] != false {
			t.Fatalf("Claude readiness = %#v, want signed-out but startable", runtime)
		}
		if runtime["readiness_issue"] != "authentication_required" {
			t.Fatalf("readiness_issue = %#v, want authentication_required", runtime["readiness_issue"])
		}
		encoded, _ := json.Marshal(runtime)
		if strings.Contains(string(encoded), "person@example.com") || strings.Contains(string(encoded), "secret-token") {
			t.Fatalf("readiness leaked auth output: %s", encoded)
		}
	})

	t.Run("malformed auth output is a stable probe failure", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "malformed")
		command := fakeClaudeRuntimeCommand(t)
		runtime := portableRuntimeEntry("claude", command, "agent-sdk-stream-json", []string{"stdio"})
		if runtime["readiness_issue"] != "runtime_probe_failed" || runtime["ready"] != false {
			t.Fatalf("malformed auth readiness = %#v", runtime)
		}
		if strings.Contains(stringFromAny(runtime["last_error"]), "secret-token") {
			t.Fatalf("probe failure leaked command output: %#v", runtime["last_error"])
		}
	})

	for _, method := range []string{"api_key", "oauth_token"} {
		t.Run(method+" requires provider verification", func(t *testing.T) {
			t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", method)
			runtime := portableRuntimeEntry("claude", fakeClaudeRuntimeCommand(t), "agent-sdk-stream-json", []string{"stdio"})
			if runtime["ready"] != false || runtime["auth_ready"] != false || runtime["readiness_issue"] != "verification_required" || stringParam(mapParam(runtime, "auth"), "status") != "configured" {
				t.Fatalf("local credential became authenticated: %#v", runtime)
			}
		})
	}

	t.Run("unknown auth method is not supported configuration", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "unknown_method")
		runtime := portableRuntimeEntry("claude", fakeClaudeRuntimeCommand(t), "agent-sdk-stream-json", []string{"stdio"})
		if runtime["ready"] != false || stringParam(mapParam(runtime, "auth"), "status") != "unknown" {
			t.Fatalf("unknown method became supported configuration: %#v", runtime)
		}
	})

	t.Run("command failure is unavailable without leaking output", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "failed")
		command := fakeClaudeRuntimeCommand(t)
		runtime := portableRuntimeEntry("claude", command, "agent-sdk-stream-json", []string{"stdio"})
		if runtime["readiness_issue"] != "runtime_probe_failed" || runtime["ready"] != false {
			t.Fatalf("failed auth command readiness = %#v", runtime)
		}
		if strings.Contains(stringFromAny(runtime["last_error"]), "secret-token") {
			t.Fatalf("command failure leaked command output: %#v", runtime["last_error"])
		}
	})

	t.Run("authenticated command must complete stream-json initialize", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "startup_failure")
		command := fakeClaudeRuntimeCommand(t)
		runtime := portableRuntimeEntry("claude", command, "agent-sdk-stream-json", []string{"stdio"})
		if runtime["native_server_startable"] != false || runtime["ready"] != false {
			t.Fatalf("Claude with broken stream-json startup was reported ready: %#v", runtime)
		}
		if runtime["readiness_issue"] != "native_server_unavailable" {
			t.Fatalf("readiness_issue = %#v, want native_server_unavailable", runtime["readiness_issue"])
		}
		encoded, _ := json.Marshal(runtime)
		if strings.Contains(string(encoded), "secret-token") {
			t.Fatalf("startup failure leaked stderr: %s", encoded)
		}
	})

	t.Run("auth output bound aborts while reading", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "oversized_stream")
		started := time.Now()
		authReady, startable, err := probeClaudeRuntimeWithTimeout(fakeClaudeRuntimeCommand(t), 2*time.Second)
		if err == nil || authReady || startable || !strings.Contains(err.Error(), "exceeded the response bound") {
			t.Fatalf("oversized auth readiness = auth:%v startable:%v err:%v", authReady, startable, err)
		}
		if elapsed := time.Since(started); elapsed > time.Second {
			t.Fatalf("auth output bound was enforced only after process exit: %s", elapsed)
		}
	})

	t.Run("auth timeout is bounded", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "timeout")
		started := time.Now()
		authReady, startable, err := probeClaudeRuntimeWithTimeout(fakeClaudeRuntimeCommand(t), 25*time.Millisecond)
		if err == nil || authReady || startable {
			t.Fatalf("timeout readiness = auth:%v startable:%v err:%v", authReady, startable, err)
		}
		if elapsed := time.Since(started); elapsed > time.Second {
			t.Fatalf("auth timeout took %s", elapsed)
		}
		if !errors.Is(err, errRuntimeProbeFailed) || strings.Contains(err.Error(), "secret-token") {
			t.Fatalf("auth timeout error = %v", err)
		}
	})
}

func TestClaudeStandardEventsKeepOnlyCanonicalCompleteContent(t *testing.T) {
	assistant := map[string]any{
		"type": "assistant",
		"message": map[string]any{
			"role": "assistant",
			"content": []any{
				map[string]any{"type": "thinking", "thinking": "considering"},
				map[string]any{"type": "text", "text": "done"},
				map[string]any{
					"type": "tool_use", "id": "tool-1", "name": "Bash",
					"input": map[string]any{"command": "salix tool call env.exec", "secret": "drop-me"},
				},
			},
			"usage": map[string]any{"input_tokens": 10, "output_tokens": 4},
		},
	}
	events := claudeStandardEvents(assistant)
	if len(events) != 3 {
		t.Fatalf("assistant events = %d, want thinking/message/operation: %#v", len(events), events)
	}
	for _, event := range events {
		event["created_at"] = int64(1)
		canonical, err := canonicalExternalRuntimeEvent(event)
		if err != nil {
			t.Fatalf("canonical event: %v (%#v)", err, event)
		}
		if raw, _ := json.Marshal(canonical); strings.Contains(string(raw), "drop-me") {
			t.Fatalf("canonical operation leaked unapproved input: %s", raw)
		}
	}

	if events := claudeStandardEvents(map[string]any{
		"type":  "stream_event",
		"event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"text": "duplicate"}},
	}); len(events) != 0 {
		t.Fatalf("token deltas must not be persisted: %#v", events)
	}

	toolResult := claudeStandardEvents(map[string]any{
		"type": "user",
		"message": map[string]any{
			"role": "user",
			"content": []any{map[string]any{
				"type": "tool_result", "tool_use_id": "tool-1", "content": "raw tool output",
			}},
		},
	})
	if len(toolResult) != 1 || toolResult[0]["type"] != "operation" || toolResult[0]["status"] != "completed" {
		t.Fatalf("tool result mapping = %#v", toolResult)
	}
}

func TestClaudeRuntimeAcceptsByReplayAndInterruptsBeforeSteer(t *testing.T) {
	promptCapture := filepath.Join(t.TempDir(), "received-system-prompt")
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_PROMPT_CAPTURE", promptCapture)
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_HOLD_FIRST", "1")
	t.Setenv("ANTHROPIC_API_KEY", "connected-api-key")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "connected-auth-token")
	t.Setenv("ANTHROPIC_BASE_URL", "https://connected.example")
	logPath := filepath.Join(t.TempDir(), "claude.log")
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", logPath)
	command := fakeClaudeRuntimeCommand(t)
	root := t.TempDir()
	c, err := newConnector(config{name: "claude-test", root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	defer func() {
		if c.bridgeServer != nil {
			_ = c.bridgeServer.Shutdown(context.Background())
		}
	}()
	implementation, ok := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
	if !ok {
		t.Fatalf("Claude implementation missing: %#v", c.runtimeImplementations)
	}
	workspace := t.TempDir()
	resolvedWorkspace, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		t.Fatal(err)
	}
	first := externalRuntimeInput{
		executionID: "execution-1",
		sessionID:   "salix-session", dispatchID: "dispatch-1", token: "token-1",
		command: command, workspace: workspace,
		systemPrompt: strings.Repeat("system instruction\n", 9000),
		messages:     []map[string]any{{"role": "user", "content": "first prompt"}},
	}
	payload, firstExecution, err := implementation.Send(context.Background(), first)
	if err != nil {
		t.Fatal(err)
	}
	receivedPrompt, err := os.ReadFile(promptCapture)
	if err != nil || string(receivedPrompt) != externalRuntimeSystemPrompt(first.systemPrompt) {
		t.Fatalf("Claude did not receive the complete large system prompt: %v", err)
	}
	promptPath, err := os.ReadFile(promptCapture + ".path")
	if err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(string(promptPath)); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("private system prompt is unavailable while Claude runs: %v", err)
	}
	t.Cleanup(func() {
		if _, err := os.Stat(string(promptPath)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("temporary system prompt remains after process exit: %v", err)
		}
	})
	nativeID := stringParam(payload, "session_id")
	if !validClaudeSessionID(nativeID) || firstExecution == "" {
		t.Fatalf("invalid native/execution identity: payload=%#v execution=%q", payload, firstExecution)
	}

	second := first
	second.dispatchID, second.token = "dispatch-2", "token-2"
	second.messages = []map[string]any{{"role": "user", "content": "second prompt"}}
	secondPayload, secondExecution, err := implementation.Send(context.Background(), second)
	if err != nil {
		t.Fatal(err)
	}
	if stringParam(secondPayload, "session_id") != nativeID || secondExecution != firstExecution {
		t.Fatalf("steer changed identity: first=%#v/%q second=%#v/%q", payload, firstExecution, secondPayload, secondExecution)
	}

	deadline := time.Now().Add(2 * time.Second)
	var log string
	for time.Now().Before(deadline) {
		raw, _ := os.ReadFile(logPath)
		log = string(raw)
		if strings.Contains(log, "second prompt") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	interruptAt, secondAt := strings.Index(log, `"subtype":"interrupt"`), strings.Index(log, "second prompt")
	if interruptAt < 0 || secondAt < 0 || interruptAt > secondAt {
		t.Fatalf("interrupt was not accepted before the steer input:\n%s", log)
	}
	for _, want := range []string{
		"--input-format stream-json", "--output-format stream-json", "--replay-user-messages",
		"--permission-mode bypassPermissions", "--allow-dangerously-skip-permissions",
		"session=" + nativeID, "salix_cli=", "context=", "cwd=" + resolvedWorkspace,
		"provider_env=connected-api-key/connected-auth-token/https://connected.example",
	} {
		if !strings.Contains(log, want) {
			t.Fatalf("Claude process log missing %q:\n%s", want, log)
		}
	}
}

func TestClaudeRuntimeRecoveryResumesExactNativeSession(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "claude-recovery.log")
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", logPath)
	command := fakeClaudeRuntimeCommand(t)
	c, err := newConnector(config{name: "claude-recovery-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	defer func() {
		if c.bridgeServer != nil {
			_ = c.bridgeServer.Shutdown(context.Background())
		}
	}()
	implementation := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
	nativeID, err := newClaudeSessionID()
	if err != nil {
		t.Fatal(err)
	}
	input := externalRuntimeInput{
		sessionID: "recover-session", dispatchID: "recover-dispatch", executionID: "recover-execution",
		token: "recover-token", command: command, workspace: t.TempDir(),
		payload: map[string]any{"session_id": nativeID},
	}
	if err := c.watchExternalRuntime("claude", input); err != nil {
		t.Fatal(err)
	}
	record := externalRuntimeRecoveryRecordFromInput("claude", input)
	interruptWatchedExecution(t, c, record)
	if err := implementation.Restore(input); err != nil {
		t.Fatal(err)
	}
	if err := implementation.Check(context.Background(), input.sessionID); err != nil {
		t.Fatal(err)
	}

	log, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"--resume=" + nativeID, "The previous execution was interrupted outside the runtime"} {
		if !strings.Contains(string(log), want) {
			t.Fatalf("Claude recovery log missing %q:\n%s", want, log)
		}
	}
	foundRecovered := false
	for _, event := range runtimeEventPayloads(t, c) {
		if event["provider"] == "claude" && event["name"] == "runtime_recovered" && event["state"] == "recovered" {
			foundRecovered = true
		}
	}
	if !foundRecovered {
		t.Fatalf("runtime_recovered was not persisted: %#v", runtimeEventPayloads(t, c))
	}
}

func TestClaudeRuntimeProtocolFailuresAreImmediateAndSecretFree(t *testing.T) {
	tests := []struct {
		name        string
		mode        string
		want        string
		eventIssue  string
		maxDuration time.Duration
	}{
		{name: "invalid json", mode: "invalid_json", want: "invalid_json"},
		{name: "oversized json", mode: "oversized_json", want: "response_too_large", maxDuration: 3 * time.Second},
		{name: "stdout closed", mode: "stdout_closed", want: "stdout_closed"},
		{name: "stderr auth", mode: "stderr_auth", want: "authentication_required", eventIssue: "authentication_required"},
		{name: "stderr quota", mode: "stderr_quota", want: "quota_exhausted", eventIssue: "quota_exhausted"},
		{name: "stderr protocol", mode: "stderr_protocol", want: "unsupported_stream_json", eventIssue: "runtime_failed"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("SALIX_TEST_FAKE_CLAUDE_PROTOCOL", tt.mode)
			command := fakeClaudeRuntimeCommand(t)
			c, err := newConnector(config{name: "claude-protocol-test", root: t.TempDir(), systemInfoInterval: 0})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			defer func() {
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
			}()
			implementation := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			started := time.Now()
			_, _, err = implementation.Send(ctx, externalRuntimeInput{
				executionID: "execution-1",
				sessionID:   "protocol-session", dispatchID: "protocol-dispatch", token: "protocol-token",
				command: command, workspace: t.TempDir(),
				messages: []map[string]any{{"role": "user", "content": "trigger protocol failure"}},
			})
			cancel()
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("protocol error = %v, want stable category %q", err, tt.want)
			}
			if strings.Contains(err.Error(), "secret-token") {
				t.Fatalf("protocol error leaked stderr: %v", err)
			}
			maxDuration := tt.maxDuration
			if maxDuration == 0 {
				maxDuration = time.Second
			}
			if elapsed := time.Since(started); elapsed > maxDuration {
				t.Fatalf("protocol failure took %s", elapsed)
			}
			deadline := time.Now().Add(time.Second)
			for len(implementation.RuntimePIDs()) != 0 && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if pids := implementation.RuntimePIDs(); len(pids) != 0 {
				t.Fatalf("protocol failure left Claude process running: %v", pids)
			}
			foundIssue := false
			for _, event := range runtimeEventPayloads(t, c) {
				raw, _ := json.Marshal(event)
				if strings.Contains(string(raw), "secret-token") {
					t.Fatalf("protocol failure event leaked stderr: %s", raw)
				}
				if tt.eventIssue != "" && event["type"] == "error" && event["issue"] == tt.eventIssue {
					foundIssue = true
				}
			}
			if tt.eventIssue != "" && !foundIssue {
				t.Fatalf("protocol failure did not persist issue %q: %#v", tt.eventIssue, runtimeEventPayloads(t, c))
			}
		})
	}
}

func TestClaudeCloseWaitIsBounded(t *testing.T) {
	started := time.Now()
	if waitClaudeDone(make(chan struct{}), 25*time.Millisecond) {
		t.Fatal("an open process completion signal was reported closed")
	}
	if elapsed := time.Since(started); elapsed < 20*time.Millisecond || elapsed > time.Second {
		t.Fatalf("bounded close wait took %s", elapsed)
	}
}

func TestClaudeCloseStopsRunningSession(t *testing.T) {
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_HOLD_FIRST", "1")
	command := fakeClaudeRuntimeCommand(t)
	c, err := newConnector(config{name: "claude-close-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		c.closeExternalRuntimes()
		if c.bridgeServer != nil {
			_ = c.bridgeServer.Shutdown(context.Background())
		}
	}()
	implementation := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
	if _, _, err := implementation.Send(context.Background(), externalRuntimeInput{
		executionID: "execution-1",
		sessionID:   "close-session", dispatchID: "close-dispatch", token: "close-token",
		command: command, workspace: t.TempDir(),
		messages: []map[string]any{{"role": "user", "content": "hold this process open"}},
	}); err != nil {
		t.Fatal(err)
	}
	pids := implementation.RuntimePIDs()
	if len(pids) != 1 || !processAlive(pids[0]) {
		t.Fatalf("running Claude process = %v", pids)
	}

	implementation.Close()
	deadline := time.Now().Add(time.Second)
	for processAlive(pids[0]) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if processAlive(pids[0]) {
		t.Fatalf("Claude process %d survived Close", pids[0])
	}
	if remaining := implementation.RuntimePIDs(); len(remaining) != 0 {
		t.Fatalf("Claude runtime still reports PIDs after Close: %v", remaining)
	}
}

func fakeClaudeRuntimeCommand(t *testing.T) string {
	t.Helper()
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := filepath.Join(t.TempDir(), "claude")
	script := `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "2.1.258 (Claude Code)"
  exit 0
fi
settings_path=""
if [ "$1" = "--settings" ]; then
  settings_path="$2"
  shift 2
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
  if [ -n "$settings_path" ]; then
    has_auth_token=false
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *ANTHROPIC_AUTH_TOKEN*|*CLAUDE_CODE_OAUTH_TOKEN*) has_auth_token=true ;; esac
    done < "$settings_path"
    if [ "$has_auth_token" = true ]; then
      echo '{"loggedIn":true,"authMethod":"oauth_token"}'
    else
      echo '{"loggedIn":true,"authMethod":"api_key"}'
    fi
    exit 0
  fi
  case "${SALIX_TEST_FAKE_CLAUDE_AUTH:-authenticated}" in
    authenticated) echo '{"loggedIn":true,"authMethod":"claude.ai"}'; exit 0 ;;
    api_key|oauth_token|unknown_method) echo "{\"loggedIn\":true,\"authMethod\":\"$SALIX_TEST_FAKE_CLAUDE_AUTH\"}"; exit 0 ;;
    signed_out) echo '{"loggedIn":false,"email":"person@example.com","token":"secret-token"}'; exit 1 ;;
    malformed) echo 'secret-token-not-json'; exit 1 ;;
    failed) echo '{"loggedIn":true,"token":"secret-token"}'; exit 1 ;;
    timeout) sleep 5; echo '{"loggedIn":true,"token":"secret-token"}'; exit 0 ;;
    startup_failure) echo '{"loggedIn":true,"authMethod":"claude.ai","token":"secret-token"}'; exit 0 ;;
    oversized_stream)
      i=0
      while [ "$i" -lt 400 ]; do
        printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        i=$((i + 1))
      done
      sleep 5
      exit 0
      ;;
  esac
fi
if [ "${SALIX_TEST_FAKE_CLAUDE_AUTH:-}" = "startup_failure" ]; then
  echo 'stream-json unsupported secret-token' >&2
  exit 42
fi
for arg in "$@"; do
  if [ "$arg" = "--safe-mode" ]; then
    if [ "${SALIX_TEST_FAKE_CLAUDE_VERIFY_REJECT:-}" = "1" ]; then
      printf '{"is_error":true,"result":"401 authentication_error"}'
      exit 1
    fi
    printf '{"is_error":false,"result":"OK"}'
    exit 0
  fi
done
SALIX_TEST_FAKE_CLAUDE=1 exec ` + shellQuote(executable) + ` -test.run=^TestHelperClaudeAgentSDK$ -- "$@"
`
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return command
}

func TestHelperClaudeAgentSDK(t *testing.T) {
	if os.Getenv("SALIX_TEST_FAKE_CLAUDE") != "1" {
		return
	}
	args := helperProcessArgs()
	logPath := os.Getenv("SALIX_TEST_FAKE_CLAUDE_LOG")
	if capture := os.Getenv("SALIX_TEST_FAKE_CLAUDE_PROMPT_CAPTURE"); capture != "" {
		found := false
		for index, arg := range args {
			if arg != "--append-system-prompt-file" || index+1 >= len(args) {
				continue
			}
			path := args[index+1]
			info, err := os.Stat(path)
			if err != nil || info.Mode().Perm() != 0o600 {
				os.Exit(2)
			}
			prompt, err := os.ReadFile(path)
			if err != nil || os.WriteFile(capture, prompt, 0o600) != nil || os.WriteFile(capture+".path", []byte(path), 0o600) != nil {
				os.Exit(2)
			}
			found = true
		}
		if !found {
			os.Exit(2)
		}
	}
	nativeID := ""
	for _, arg := range args {
		if strings.HasPrefix(arg, "--session-id=") {
			nativeID = strings.TrimPrefix(arg, "--session-id=")
		}
		if strings.HasPrefix(arg, "--resume=") {
			nativeID = strings.TrimPrefix(arg, "--resume=")
		}
	}
	if nativeID == "" {
		fmt.Fprintln(os.Stderr, "fake Claude received no session identity")
		os.Exit(2)
	}
	appendFakeProcessLog(logPath, "start "+strings.Join(args, " "))
	appendFakeProcessLog(logPath, "session="+nativeID)
	appendFakeProcessLog(logPath, "context="+os.Getenv("SALIX_RUNTIME_CONTEXT"))
	appendFakeProcessLog(logPath, "salix_cli="+os.Getenv("SALIX_CLI"))
	appendFakeProcessLog(logPath, "provider_env="+os.Getenv("ANTHROPIC_API_KEY")+"/"+os.Getenv("ANTHROPIC_AUTH_TOKEN")+"/"+os.Getenv("ANTHROPIC_BASE_URL"))
	if cwd, err := os.Getwd(); err == nil {
		appendFakeProcessLog(logPath, "cwd="+cwd)
	}

	encoder := json.NewEncoder(os.Stdout)
	var writeMu sync.Mutex
	write := func(value map[string]any) {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = encoder.Encode(value)
	}
	turn := 0
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request map[string]any
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			continue
		}
		appendFakeProcessLog(logPath, string(scanner.Bytes()))
		switch stringParam(request, "type") {
		case "control_request":
			control := mapParam(request, "request")
			subtype := stringParam(control, "subtype")
			write(map[string]any{"type": "control_response", "response": map[string]any{
				"subtype": "success", "request_id": request["request_id"], "response": map[string]any{
					"models": []any{map[string]any{"value": "default", "resolvedModel": "claude-test-model"}},
				},
			}})
			if subtype == "interrupt" {
				write(map[string]any{
					"type": "result", "subtype": "error_during_execution", "is_error": true,
					"errors": []any{"Interrupted by user"}, "session_id": nativeID,
				})
			}
		case "user":
			runFakeManagedProviderRequest("claude", "managed-model")
			switch os.Getenv("SALIX_TEST_FAKE_CLAUDE_PROTOCOL") {
			case "invalid_json":
				fmt.Fprintln(os.Stdout, "{not-json}")
				time.Sleep(5 * time.Second)
			case "oversized_json":
				fmt.Fprintln(os.Stdout, `{"type":"status","status":"`+strings.Repeat("x", maxFile)+`"}`)
				time.Sleep(5 * time.Second)
			case "stdout_closed":
				_ = os.Stdout.Close()
				time.Sleep(5 * time.Second)
			case "stderr_auth":
				fmt.Fprintln(os.Stderr, "not logged in token=secret-token")
				_ = os.Stdout.Close()
				os.Exit(42)
			case "stderr_quota":
				fmt.Fprintln(os.Stderr, "usage limit reached token=secret-token")
				_ = os.Stdout.Close()
				os.Exit(42)
			case "stderr_protocol":
				fmt.Fprintln(os.Stderr, "unknown option --input-format stream-json token=secret-token")
				_ = os.Stdout.Close()
				os.Exit(42)
			}
			turn++
			request["session_id"] = nativeID
			write(map[string]any{
				"type": "system", "subtype": "init", "session_id": nativeID,
				"model": "claude-test", "permissionMode": "bypassPermissions",
			})
			write(request)
			if os.Getenv("SALIX_TEST_FAKE_CLAUDE_USAGE_LIMIT") == "1" {
				write(map[string]any{"type": "rate_limit_event", "rate_limit_info": map[string]any{
					"status": "rejected", "resetsAt": 1789480200,
				}})
				if turn == 1 {
					write(map[string]any{"type": "assistant", "error": "rate_limit", "message": map[string]any{
						"role": "assistant", "content": []any{map[string]any{"type": "text", "text": "You've hit your session limit"}},
					}})
					// Some CLI versions finish a synthetic API error with a success result.
					write(map[string]any{"type": "result", "subtype": "success", "is_error": false, "usage": map[string]any{"input_tokens": 42}})
					continue
				}
				if turn == 3 {
					write(map[string]any{"type": "result", "subtype": "error_max_turns", "is_error": true,
						"errors": []any{"maximum turns reached"}})
					continue
				}
				// A rejection followed by successful fallback is not terminal.
			}
			write(map[string]any{
				"type": "assistant", "session_id": nativeID,
				"message": map[string]any{
					"role": "assistant",
					"content": []any{
						map[string]any{"type": "thinking", "thinking": "considering"},
						map[string]any{"type": "text", "text": "accepted"},
						map[string]any{"type": "tool_use", "id": fmt.Sprintf("tool-%d", turn), "name": "Bash", "input": map[string]any{"command": "pwd"}},
					},
					"usage": map[string]any{"input_tokens": 2, "output_tokens": 1},
				},
			})
			if turn > 1 || os.Getenv("SALIX_TEST_FAKE_CLAUDE_HOLD_FIRST") != "1" {
				write(map[string]any{
					"type": "result", "subtype": "success", "is_error": false,
					"result": "accepted", "session_id": nativeID,
					"usage": map[string]any{"input_tokens": 2, "output_tokens": 1},
				})
			}
		}
	}
	os.Exit(0)
}

func TestClaudeUsageFailureDoesNotInterpretOrdinaryAssistantText(t *testing.T) {
	native := map[string]any{"message": map[string]any{"content": []any{
		map[string]any{"type": "text", "text": "You've hit your session limit · resets 1:50pm (UTC)"},
	}}}
	if got := claudeAPIUsageFailure(native); got != nil {
		t.Fatalf("ordinary prose became an API error: %#v", got)
	}
	native["error"] = "rate_limit"
	if got := claudeAPIUsageFailure(native); got["issue"] != "quota_exhausted" {
		t.Fatalf("SDK quota error was not classified: %#v", got)
	}
}

func TestClaudeUsageLimitSettlesFailedAndNextTurnCanRecover(t *testing.T) {
	t.Setenv("SALIX_TEST_FAKE_CLAUDE_USAGE_LIMIT", "1")
	command := fakeClaudeRuntimeCommand(t)
	c, err := newConnector(config{name: "claude-limit-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	defer func() {
		if c.bridgeServer != nil {
			_ = c.bridgeServer.Shutdown(context.Background())
		}
	}()
	implementation := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
	input := externalRuntimeInput{
		executionID: "execution-1",
		sessionID:   "usage-session", dispatchID: "limited-dispatch", token: "usage-token",
		command: command, workspace: t.TempDir(),
		messages: []map[string]any{{"role": "user", "content": "test"}},
	}
	_, _, err = implementation.Send(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	found := false
	for time.Now().Before(deadline) {
		for _, event := range runtimeEventPayloads(t, c) {
			if event["dispatch_id"] == input.dispatchID && event["work_state"] == "failed" {
				if event["issue"] != "quota_exhausted" || event["message"] != "Claude account usage quota is exhausted. Provider reset time: 2026-09-15T13:50:00Z." {
					t.Fatalf("missing quota/reset detail: %#v", event)
				}
				if intFromAny(mapParam(event, "usage")["input_tokens"], 0) != 42 {
					t.Fatalf("terminal usage was lost: %#v", event)
				}
				found = true
			}
			if event["dispatch_id"] == input.dispatchID && event["work_state"] == "settled" {
				t.Fatalf("limited turn reported success: %#v", event)
			}
		}
		if found {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !found {
		t.Fatal("no terminal usage-limit event persisted")
	}
	// Reconnection must not overwrite the reason with generic runtime_failed.
	implementation.ReplayObservations()
	input.dispatchID = "recovered-dispatch"
	input.executionID = "execution-2"
	if _, _, err := implementation.Send(context.Background(), input); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		for _, event := range runtimeEventPayloads(t, c) {
			if event["dispatch_id"] == input.dispatchID && event["work_state"] == "failed" {
				t.Fatalf("previous turn's failure leaked into recovery: %#v", event)
			}
			if event["dispatch_id"] == input.dispatchID && event["work_state"] == "settled" {
				input.dispatchID = "unrelated-failure-dispatch"
				input.executionID = "execution-3"
				if _, _, err := implementation.Send(context.Background(), input); err != nil {
					t.Fatal(err)
				}
				failureDeadline := time.Now().Add(3 * time.Second)
				for time.Now().Before(failureDeadline) {
					for _, final := range runtimeEventPayloads(t, c) {
						if final["dispatch_id"] == input.dispatchID && final["work_state"] == "failed" {
							if final["issue"] != "runtime_failed" || final["code"] != "error_max_turns" || final["usage_reset_at"] != nil || strings.Contains(stringParam(final, "message"), "reset") {
								t.Fatalf("rejected warning misclassified unrelated failure: %#v", final)
							}
							return
						}
					}
					time.Sleep(10 * time.Millisecond)
				}
				t.Fatal("non-quota failure was not reported")
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("next successful turn did not settle")
}
