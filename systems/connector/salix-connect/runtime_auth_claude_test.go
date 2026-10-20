package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeAuthClaudeBackendRejectsExecutableAndCrossBackendInput(t *testing.T) {
	for _, test := range []struct {
		name, backend, input string
		valid                bool
	}{
		{"openrouter", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":""}}`, true},
		{"setup token", "anthropic", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-token"}}`, true},
		{"mixed token", "anthropic", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-token","ANTHROPIC_API_KEY":"other"}}`, false},
		{"token endpoint", "anthropic", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-token","ANTHROPIC_BASE_URL":"https://example.com"}}`, false},
		{"anthropic", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"}}`, true},
		{"foreign endpoint", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://example.com/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":""}}`, false},
		{"missing empty api key", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key"}}`, false},
		{"competing api key", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":"other-key"}}`, false},
		{"cross backend", "anthropic", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":""}}`, false},
		{"helper", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"},"apiKeyHelper":"touch /tmp/never"}`, false},
		{"hook", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"},"hooks":{}}`, false},
		{"indirect env", "anthropic", `{"env":{"ANTHROPIC_API_KEY":{"env":"SECRET"}}}`, false},
		{"duplicate", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"one","ANTHROPIC_API_KEY":"two"}}`, false},
		{"null", "anthropic", `{"env":{"ANTHROPIC_API_KEY":null}}`, false},
		{"unsupported backend", "other", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"}}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseRuntimeAuthClaudeBackend([]byte(test.input), test.backend)
			if (err == nil) != test.valid {
				t.Fatalf("accepted = %v, want %v", err == nil, test.valid)
			}
		})
	}
}

func TestRuntimeAuthClaudeExecEnvIsolatesOnlyManagedProfiles(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "host-api-key")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "host-auth-token")
	t.Setenv("ANTHROPIC_BASE_URL", "https://host.example")
	t.Setenv("CLAUDE_CODE_OAUTH_TOKEN", "host-setup-token")
	t.Setenv("SALIX_TEST_ENV", "preserved")

	isolated := strings.Join(runtimeAuthClaudeExecEnv(map[string]any{"PATH": "/managed/bin"}, true), "\n")
	for _, forbidden := range []string{"ANTHROPIC_API_KEY=", "ANTHROPIC_AUTH_TOKEN=", "ANTHROPIC_BASE_URL=", "CLAUDE_CODE_OAUTH_TOKEN="} {
		if strings.Contains(isolated, forbidden) {
			t.Fatalf("isolated Claude environment retained %q", forbidden)
		}
	}
	for _, want := range []string{"PATH=/managed/bin", "SALIX_TEST_ENV=preserved"} {
		if !strings.Contains(isolated, want) {
			t.Fatalf("isolated Claude environment omitted %q:\n%s", want, isolated)
		}
	}

	connected := strings.Join(runtimeAuthClaudeExecEnv(map[string]any{"PATH": "/connected/bin"}, false), "\n")
	for _, want := range []string{
		"ANTHROPIC_API_KEY=host-api-key", "ANTHROPIC_AUTH_TOKEN=host-auth-token",
		"ANTHROPIC_BASE_URL=https://host.example", "PATH=/connected/bin",
	} {
		if !strings.Contains(connected, want) {
			t.Fatalf("connected Claude environment omitted %q:\n%s", want, connected)
		}
	}
}

func TestRuntimeAuthClaudeVerificationIsBoundedAndToolFree(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", directory)
	settings := []byte(`{"env":{"ANTHROPIC_API_KEY":"synthetic-key"}}`)
	path, _ := runtimeAuthClaudeLocation()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, settings, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ANTHROPIC_API_KEY", "host-api-key")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "host-auth-token")
	t.Setenv("ANTHROPIC_BASE_URL", "https://host.example")
	logPath := filepath.Join(t.TempDir(), "args.json")
	command := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shellQuote(logPath) + "\nprintf '%s\\n' \"$CLAUDE_CODE_MAX_OUTPUT_TOKENS/$CLAUDE_CODE_MAX_RETRIES/$MAX_THINKING_TOKENS\" >> " + shellQuote(logPath) + "\nprintf 'provider-env=%s/%s/%s\\n' \"${ANTHROPIC_API_KEY-unset}\" \"${ANTHROPIC_AUTH_TOKEN-unset}\" \"${ANTHROPIC_BASE_URL-unset}\" >> " + shellQuote(logPath) + "\nprintf '{\"is_error\":false,\"result\":\"OK\"}'\n"
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	result := verifyRuntimeAuthClaude(context.Background(), command, "anthropic", "claude-test-model")
	if result.Status != "authenticated" || result.Issue != "" {
		t.Fatalf("verification = %+v", result)
	}
	log, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(log)
	for _, want := range []string{"--settings\n" + path, "--safe-mode", "--setting-sources\n\n", "--strict-mcp-config", "--tools\n\n", "--no-session-persistence", "--model\nclaude-test-model", "64/0/0", "provider-env=unset/unset/unset"} {
		if !strings.Contains(text, want) {
			t.Fatalf("verification omitted %q:\n%s", want, text)
		}
	}
}

func TestClaudeVerificationIssueClassification(t *testing.T) {
	for input, want := range map[string]string{
		`status 401 authentication_error`: "credentials_rejected",
		`status 403 forbidden`:            "permission_denied",
		`status 429 rate limit`:           "rate_limited",
		`status 402 credit balance`:       "quota_exhausted",
		`model not found`:                 "verification_model_unavailable",
		`connection reset`:                "provider_unavailable",
	} {
		if got := claudeVerificationIssue(input, ""); got != want {
			t.Fatalf("%q = %q, want %q", input, got, want)
		}
	}
}
