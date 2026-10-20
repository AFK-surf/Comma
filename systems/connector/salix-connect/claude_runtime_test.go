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
		t.Run(method+" can dispatch without provider verification", func(t *testing.T) {
			t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", method)
			command := fakeClaudeRuntimeCommand(t)
			c := newBareTestConnector(t, t.TempDir())
			c.runtimeInventory = newRuntimeInventory()
			implementation := newCodexRuntimeImplementation(c)
			c.runtimeImplementations = map[string]runtimeImplementation{"codex": implementation}
			c.runtimeInventory.commitGuard = implementation.commitRuntimeProbe
			target := runtimeProbeTarget{provider: "claude", identityMaterial: command}
			runtime, err := c.runtimeInventory.probeOne(context.Background(), target, "connect")
			if err != nil {
				t.Fatal(err)
			}
			if runtime["ready"] != true || runtime["auth_ready"] != true || runtime["readiness_issue"] != nil || stringParam(mapParam(runtime, "auth"), "status") != "configured" {
				t.Fatalf("configured Claude must be usable without claiming provider verification: %#v", runtime)
			}
			status := implementation.auth.status(context.Background(), target, "admin")
			if status["dispatch_ready"] != true || stringParam(mapParam(status, "auth"), "status") != "configured" {
				t.Fatalf("auth panel must permit dispatch without claiming verification: %#v", status)
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

	// The fake keeps its stdout open after the oversized output until it is
	// killed, and the probe's own timeout is far away: the probe returns only
	// if it stops reading at the bound.
	t.Run("auth output bound aborts while reading", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "oversized_stream")
		authReady, startable, err := probeClaudeRuntimeWithTimeout(fakeClaudeRuntimeCommand(t), time.Hour)
		if err == nil || authReady || startable || !strings.Contains(err.Error(), "exceeded the response bound") {
			t.Fatalf("oversized auth readiness = auth:%v startable:%v err:%v", authReady, startable, err)
		}
	})

	// The fake never answers and holds its stdout open until it is killed: the
	// probe returns only through its timeout, by killing the process.
	t.Run("auth timeout is bounded", func(t *testing.T) {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "timeout")
		authReady, startable, err := probeClaudeRuntimeWithTimeout(fakeClaudeRuntimeCommand(t), 25*time.Millisecond)
		if err == nil || authReady || startable {
			t.Fatalf("timeout readiness = auth:%v startable:%v err:%v", authReady, startable, err)
		}
		if !errors.Is(err, errRuntimeProbeFailed) || strings.Contains(err.Error(), "secret-token") {
			t.Fatalf("auth timeout error = %v", err)
		}
	})
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
  echo "2.1.296 (Claude Code)"
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
    timeout) while :; do sleep 3600; done ;;
    startup_failure) echo '{"loggedIn":true,"authMethod":"claude.ai","token":"secret-token"}'; exit 0 ;;
    oversized_stream)
      i=0
      while [ "$i" -lt 400 ]; do
        printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        i=$((i + 1))
      done
      while :; do sleep 3600; done
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

// TestHelperClaudeAgentSDK is the fake Claude stream-json process that
// readiness probes initialize.
func TestHelperClaudeAgentSDK(t *testing.T) {
	if os.Getenv("SALIX_TEST_FAKE_CLAUDE") != "1" {
		return
	}
	args := helperProcessArgs()
	logPath := os.Getenv("SALIX_TEST_FAKE_CLAUDE_LOG")
	nativeID := ""
	for _, arg := range args {
		if strings.HasPrefix(arg, "--session-id=") {
			nativeID = strings.TrimPrefix(arg, "--session-id=")
		}
	}
	if nativeID == "" {
		fmt.Fprintln(os.Stderr, "fake Claude received no session identity")
		os.Exit(2)
	}
	appendFakeProcessLog(logPath, "start "+strings.Join(args, " "))
	appendFakeProcessLog(logPath, "provider_env="+os.Getenv("ANTHROPIC_API_KEY")+"/"+os.Getenv("ANTHROPIC_AUTH_TOKEN")+"/"+os.Getenv("ANTHROPIC_BASE_URL"))

	encoder := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request map[string]any
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			continue
		}
		appendFakeProcessLog(logPath, string(scanner.Bytes()))
		if stringParam(request, "type") == "control_request" {
			_ = encoder.Encode(map[string]any{"type": "control_response", "response": map[string]any{
				"subtype": "success", "request_id": request["request_id"], "response": map[string]any{
					"models": []any{map[string]any{"value": "default", "resolvedModel": "claude-test-model"}},
				},
			}})
		}
	}
	os.Exit(0)
}
