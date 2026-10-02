package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

const runtimeAuthClaudeSettingsName = "salix-auth-settings.json"
const runtimeAuthClaudeCredentialsName = ".credentials.json"
const runtimeAuthClaudeVersion = "2.1.258"

var runtimeAuthClaudeRateLimitTier = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

func runtimeAuthClaudeVersionSupported(version string) bool {
	fields := strings.Fields(strings.TrimSpace(version))
	return len(fields) > 0 && fields[0] == runtimeAuthClaudeVersion
}

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

func runtimeAuthClaudeSettings(backend, key string) ([]byte, error) {
	if !runtimeAuthCodexToken(key) {
		return nil, errRuntimeAuthInputInvalid
	}
	env := map[string]string{"ANTHROPIC_API_KEY": key}
	if backend == "openrouter" {
		env = map[string]string{
			"ANTHROPIC_BASE_URL":   "https://openrouter.ai/api",
			"ANTHROPIC_AUTH_TOKEN": key,
			"ANTHROPIC_API_KEY":    "",
		}
	} else if backend != "anthropic" {
		return nil, errRuntimeAuthInputInvalid
	}
	return json.Marshal(map[string]any{"env": env})
}

// Claude Code 2.1.258's Linux file store writes this native OAuth record. The
// adapter preserves accepted bytes and never mints or converts provider tokens.
// macOS keychain material is intentionally outside this file-mode contract.
func parseRuntimeAuthClaudeCredentials(data []byte) error {
	root, err := runtimeAuthJSONObject(data, "claudeAiOauth")
	if err != nil || len(root) != 1 {
		return errRuntimeAuthInputInvalid
	}
	fields, err := runtimeAuthJSONObject(root["claudeAiOauth"],
		"accessToken", "refreshToken", "expiresAt", "refreshTokenExpiresAt", "scopes",
		"clientId", "subscriptionType", "rateLimitTier")
	if err != nil {
		return errRuntimeAuthInputInvalid
	}
	for _, name := range []string{"accessToken", "refreshToken"} {
		var value string
		if json.Unmarshal(fields[name], &value) != nil || !runtimeAuthCodexToken(value) {
			return errRuntimeAuthInputInvalid
		}
	}
	var expiresAt int64
	if json.Unmarshal(fields["expiresAt"], &expiresAt) != nil || expiresAt <= 0 || expiresAt > 9_999_999_999_999 {
		return errRuntimeAuthInputInvalid
	}
	if raw, ok := fields["refreshTokenExpiresAt"]; ok {
		var value int64
		if json.Unmarshal(raw, &value) != nil || value <= 0 || value > 9_999_999_999_999 {
			return errRuntimeAuthInputInvalid
		}
	}
	var scopes []string
	if json.Unmarshal(fields["scopes"], &scopes) != nil || len(scopes) == 0 || len(scopes) > 16 {
		return errRuntimeAuthInputInvalid
	}
	inference := false
	seenScopes := make(map[string]struct{}, len(scopes))
	for _, scope := range scopes {
		if !runtimeAuthCodexToken(scope) || len(scope) > 128 || !strings.HasPrefix(scope, "user:") {
			return errRuntimeAuthInputInvalid
		}
		if _, duplicate := seenScopes[scope]; duplicate {
			return errRuntimeAuthInputInvalid
		}
		seenScopes[scope] = struct{}{}
		inference = inference || scope == "user:inference" || scope == "user:ccr_inference"
	}
	if !inference {
		return errRuntimeAuthInputInvalid
	}
	if raw, ok := fields["clientId"]; ok {
		var value string
		if json.Unmarshal(raw, &value) != nil || !runtimeAuthCodexToken(value) {
			return errRuntimeAuthInputInvalid
		}
	}
	if raw, ok := fields["subscriptionType"]; ok && string(raw) != "null" {
		var value string
		if json.Unmarshal(raw, &value) != nil || (value != "max" && value != "pro" && value != "team" && value != "enterprise") {
			return errRuntimeAuthInputInvalid
		}
	}
	if raw, ok := fields["rateLimitTier"]; ok && string(raw) != "null" {
		var value string
		if json.Unmarshal(raw, &value) != nil || !runtimeAuthClaudeRateLimitTier.MatchString(value) {
			return errRuntimeAuthInputInvalid
		}
	}
	return nil
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

func runtimeAuthClaudeCredentialsLocation() (string, error) {
	if runtime.GOOS != "linux" {
		return "", errors.New("claude native credential file is unsupported")
	}
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
	return filepath.Join(directory, runtimeAuthClaudeCredentialsName), nil
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

func runtimeAuthClaudeManagedExecEnv(raw map[string]any, credential *managedRuntimeCredential) []string {
	// Filter every inherited carrier first, then add exactly one credential
	// source plus the selected endpoint. This ordering prevents a personal
	// settings or shell value from replacing the organization selection.
	delete(raw, "ANTHROPIC_API_KEY")
	delete(raw, "ANTHROPIC_AUTH_TOKEN")
	delete(raw, "ANTHROPIC_BASE_URL")
	delete(raw, "CLAUDE_CODE_OAUTH_TOKEN")
	environment := runtimeAuthClaudeExecEnv(raw, true)
	environment = append(environment, "ANTHROPIC_BASE_URL="+credential.endpoint)
	if credential.oauth {
		environment = append(environment, "CLAUDE_CODE_OAUTH_TOKEN="+credential.apiKey)
	} else if credential.authScheme == "bearer" {
		environment = append(environment, "ANTHROPIC_AUTH_TOKEN="+credential.apiKey)
	} else {
		environment = append(environment, "ANTHROPIC_API_KEY="+credential.apiKey)
	}
	return environment
}

func stageRuntimeAuthClaude(ctx context.Context, authPath string, data []byte, valid func([]byte) error, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	if valid == nil || valid(data) != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
	}
	directory := filepath.Dir(authPath)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_prepare_failed"}
	}
	stage, err := os.CreateTemp(directory, ".auth-input-*")
	if err != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_prepare_failed"}
	}
	stagePath := stage.Name()
	defer os.Remove(stagePath)
	if err := stage.Chmod(0o600); err == nil {
		_, err = stage.Write(data)
	}
	if err == nil {
		err = stage.Sync()
	}
	if closeErr := stage.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_prepare_failed"}
	}
	if ctx.Err() != nil || commit == nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	return commit(stagePath)
}

func saveRuntimeAuthClaude(ctx context.Context, authPath string, data []byte, backend string, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	return stageRuntimeAuthClaude(ctx, authPath, data, func(data []byte) error {
		_, err := parseRuntimeAuthClaudeBackend(data, backend)
		return err
	}, commit)
}

func saveRuntimeAuthClaudeCredentials(ctx context.Context, authPath string, data []byte, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	return stageRuntimeAuthClaude(ctx, authPath, data, parseRuntimeAuthClaudeCredentials, commit)
}

// The settings carrier has explicit precedence over Claude's native OAuth
// store. A successful native-file commit therefore removes only the Salix-owned
// settings file under the same fenced generation. Failure never removes the
// newly committed provider credentials and is reported as a post-commit issue.
func commitRuntimeAuthClaudeCredentials(ctx context.Context, stagePath, authPath string) runtimeAuthSaveOutcome {
	outcome := commitRuntimeAuthFile(ctx, stagePath, authPath)
	if outcome.SaveResult != "committed" || outcome.Issue != "" {
		return outcome
	}
	settingsPath, err := runtimeAuthClaudeLocation()
	if err != nil {
		outcome.Issue = "storage_sync_failed"
		return outcome
	}
	if err := os.Remove(settingsPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		outcome.Issue = "storage_sync_failed"
		return outcome
	}
	directory, err := os.Open(filepath.Dir(settingsPath))
	if err != nil {
		outcome.Issue = "storage_sync_failed"
		return outcome
	}
	defer directory.Close()
	if directory.Sync() != nil {
		outcome.Issue = "storage_sync_failed"
	}
	return outcome
}

func savePrivateClaude(ctx context.Context, m *runtimeAuthCoordinator, target runtimeProbeTarget, expected runtimeAuthInputContext, envelope runtimeAuthInputEnvelope, implementation *claudeRuntimeImplementation, authPath string, current func() bool, withCarrier func(func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	if implementation == nil || withCarrier == nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	return m.savePrivateInput(ctx, target, expected, envelope, current, func(data []byte, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
		if expected.Form == "api_key" {
			key, err := parseRuntimeAuthAPIKey(data)
			if err != nil {
				return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
			}
			data, err = runtimeAuthClaudeSettings(expected.Backend, key)
			if err != nil {
				return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
			}
			defer clear(data)
		}
		if expected.Form == "claude_credentials_file" {
			return saveRuntimeAuthClaudeCredentials(ctx, authPath, data, commit)
		}
		return saveRuntimeAuthClaude(ctx, authPath, data, expected.Backend, commit)
	}, func(stage string) runtimeAuthSaveOutcome {
		return implementation.commitAuthSettings(ctx, expected.NativeGeneration, expected.AuthEpoch, func() runtimeAuthSaveOutcome {
			return withCarrier(func() runtimeAuthSaveOutcome {
				if expected.Form == "claude_credentials_file" {
					return commitRuntimeAuthClaudeCredentials(ctx, stage, authPath)
				}
				return commitRuntimeAuthFile(ctx, stage, authPath)
			})
		})
	})
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
