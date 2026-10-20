package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const runtimeAuthClaudeSettingsName = "salix-auth-settings.json"
const runtimeAuthClaudeCredentialsName = ".credentials.json"

// The native --settings carrier contains only the approved authentication
// subset. Managed settings retain native precedence; this parser does not
// authorize writes or claim that local configuration authenticates a request.
func parseRuntimeAuthClaudeBackend(data []byte, backend string) (map[string]string, error) {
	fields, err := runtimeAuthJSONObject(data, "env")
	if err != nil || len(fields) != 1 {
		return nil, errRuntimeAuthInputInvalid
	}
	env, err := runtimeAuthJSONObject(fields["env"], "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
	if err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	values := make(map[string]string, len(env))
	for key, raw := range env {
		var value string
		if json.Unmarshal(raw, &value) != nil {
			return nil, errRuntimeAuthInputInvalid
		}
		values[key] = value
	}
	switch backend {
	case "openrouter":
		if len(values) != 3 || values["ANTHROPIC_BASE_URL"] != "https://openrouter.ai/api" ||
			!runtimeAuthCodexToken(values["ANTHROPIC_AUTH_TOKEN"]) || values["ANTHROPIC_API_KEY"] != "" {
			return nil, errRuntimeAuthInputInvalid
		}
	case "anthropic":
		if len(values) != 1 || (!runtimeAuthCodexToken(values["ANTHROPIC_API_KEY"]) && !runtimeAuthCodexToken(values["CLAUDE_CODE_OAUTH_TOKEN"])) {
			return nil, errRuntimeAuthInputInvalid
		}
	default:
		return nil, errRuntimeAuthInputInvalid
	}
	return values, nil
}

// Compute Claude workloads set HOME to their stable provider_state volume.
func runtimeAuthClaudeLocation() (string, error) {
	directory := strings.TrimSpace(os.Getenv("CLAUDE_CONFIG_DIR"))
	if directory == "" {
		home, err := os.UserHomeDir()
		if err != nil || !filepath.IsAbs(home) {
			return "", errors.New("claude native auth layout is unsupported")
		}
		directory = filepath.Join(home, ".claude")
	}
	if !filepath.IsAbs(directory) {
		return "", errors.New("claude native auth layout is unsupported")
	}
	return filepath.Join(directory, runtimeAuthClaudeSettingsName), nil
}

// A missing Salix carrier preserves existing native Claude behavior. An
// existing carrier must be one exact supported profile; invalid files fail
// closed instead of being silently ignored by Claude's print mode.
func runtimeAuthClaudeProfile() (path, backend string, err error) {
	path, backend, _, err = runtimeAuthClaudeProfileMethod()
	return
}

func runtimeAuthClaudeProfileMethod() (path, backend, method string, err error) {
	path, err = runtimeAuthClaudeLocation()
	if err != nil {
		return "", "", "", err
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", "", "", nil
	}
	if err != nil {
		return "", "", "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > runtimeAuthPlaintextLimit {
		return "", "", "", errRuntimeAuthInputInvalid
	}
	data, err := io.ReadAll(io.LimitReader(file, runtimeAuthPlaintextLimit+1))
	if err != nil || len(data) > runtimeAuthPlaintextLimit {
		return "", "", "", errRuntimeAuthInputInvalid
	}
	for _, candidate := range []string{"anthropic", "openrouter"} {
		if values, parseErr := parseRuntimeAuthClaudeBackend(data, candidate); parseErr == nil {
			method := "api_key"
			if candidate == "openrouter" || values["CLAUDE_CODE_OAUTH_TOKEN"] != "" {
				method = "oauth_token"
			}
			return path, candidate, method, nil
		}
	}
	return "", "", "", errRuntimeAuthInputInvalid
}

func runtimeAuthClaudeArgs() ([]string, string, error) {
	path, backend, err := runtimeAuthClaudeProfile()
	if err != nil || path == "" {
		return nil, backend, err
	}
	return []string{"--settings", path}, backend, nil
}

func runtimeAuthClaudeExecEnv(raw map[string]any, isolateProfile bool) []string {
	environment := execEnv(raw)
	if !isolateProfile {
		return environment
	}
	blocked := map[string]bool{
		"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true, "ANTHROPIC_BASE_URL": true,
		"CLAUDE_CODE_OAUTH_TOKEN": true,
	}
	filtered := environment[:0]
	for _, item := range environment {
		name, _, _ := strings.Cut(item, "=")
		if !blocked[name] {
			filtered = append(filtered, item)
		}
	}
	return filtered
}

func verifyRuntimeAuthClaude(ctx context.Context, command, expectedBackend, model string) runtimeAuthVerificationOutcome {
	failed := runtimeAuthVerificationOutcome{Status: "error", Issue: "provider_unavailable"}
	settings, backend, err := runtimeAuthClaudeArgs()
	if err != nil || backend != expectedBackend || !runtimeAuthCodexToken(model) {
		failed.Issue = "verification_model_unavailable"
		return failed
	}
	workdir, err := os.MkdirTemp("", "salix-claude-verification-")
	if err != nil {
		return failed
	}
	defer os.RemoveAll(workdir)
	args := append([]string{}, settings...)
	args = append(args,
		"--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
		"--disable-slash-commands", "--tools", "", "--no-session-persistence", "--model", model,
		"--system-prompt", "Reply with exactly OK.", "--output-format", "json", "-p", "Reply with exactly OK.",
	)
	cmd := commandContextWithProcessGroup(ctx, command, args...)
	cmd.Dir = workdir
	cmd.Env = runtimeAuthClaudeExecEnv(map[string]any{
		"PATH":                          runtimeCommandPath(command),
		"CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64",
		"CLAUDE_CODE_MAX_RETRIES":       "0",
		"MAX_THINKING_TOKENS":           "0",
	}, true)
	cmd.WaitDelay = time.Second
	diagnostics := &harnessDiagnosticBuffer{}
	cmd.Stderr = diagnostics
	stdout, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return failed
	}
	output, readErr := io.ReadAll(io.LimitReader(stdout, 64*1024+1))
	if readErr != nil || len(output) > 64*1024 {
		killProcessGroup(cmd)
		_ = cmd.Wait()
		return failed
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return runtimeAuthVerificationOutcome{Status: "error", Issue: "canceled"}
	}
	var result struct {
		IsError bool `json:"is_error"`
	}
	if waitErr == nil && json.Unmarshal(output, &result) == nil && !result.IsError {
		return runtimeAuthVerificationOutcome{Status: "authenticated"}
	}
	issue := claudeVerificationIssue(string(output), diagnostics.text())
	status := "error"
	if issue == "credentials_rejected" {
		status = "unauthenticated"
	}
	return runtimeAuthVerificationOutcome{Status: status, Issue: issue}
}

func claudeVerificationIssue(stdout, stderr string) string {
	text := strings.ToLower(stdout + "\n" + stderr)
	switch {
	case strings.Contains(text, "401"), strings.Contains(text, "invalid x-api-key"), strings.Contains(text, "invalid api key"), strings.Contains(text, "authentication_error"):
		return "credentials_rejected"
	case strings.Contains(text, "403"), strings.Contains(text, "permission denied"), strings.Contains(text, "forbidden"):
		return "permission_denied"
	case strings.Contains(text, "429"), strings.Contains(text, "rate limit"), strings.Contains(text, "too many requests"):
		return "rate_limited"
	case strings.Contains(text, "402"), strings.Contains(text, "credit balance"), strings.Contains(text, "quota"), strings.Contains(text, "usage limit"):
		return "quota_exhausted"
	case strings.Contains(text, "model") && (strings.Contains(text, "not found") || strings.Contains(text, "does not exist")):
		return "verification_model_unavailable"
	default:
		return "provider_unavailable"
	}
}
