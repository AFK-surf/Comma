package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	runtimeReadinessValidity = 10 * time.Minute
	claudeAuthStatusMaxBytes = 16 * 1024
)

var (
	errRuntimeAuthenticationRequired = errors.New("runtime authentication required")
	errRuntimeVerificationRequired   = errors.New("runtime authentication verification required")
	errRuntimeProbeFailed            = errors.New("runtime probe failed")
	errNativeServerUnavailable       = errors.New("native server unavailable")
)

type runtimeVerificationRequiredError struct{ backend, model string }

func (err runtimeVerificationRequiredError) Error() string {
	return errRuntimeVerificationRequired.Error()
}
func (err runtimeVerificationRequiredError) Unwrap() error { return errRuntimeVerificationRequired }

func detectPortableRuntime(provider, commandName, protocol string, transports, knownPaths []string) []map[string]any {
	paths := detectCommands(commandName, knownPaths)
	runtimes := make([]map[string]any, 0, len(paths))
	for _, path := range paths {
		runtimes = append(runtimes, portableRuntimeEntry(provider, path, protocol, transports))
	}
	return runtimes
}

func portableRuntimeEntry(provider, path, protocol string, transports []string) map[string]any {
	return portableRuntimeEntryWithClaudeIsolation(provider, path, protocol, transports, false)
}

func portableRuntimeEntryWithClaudeIsolation(provider, path, protocol string, transports []string, isolateClaude bool) map[string]any {
	checkedAt := time.Now()
	version, versionErr := commandVersion(path)
	authReady, nativeServerStartable, probeErr := false, false, error(nil)
	if versionErr == nil {
		authReady, nativeServerStartable, probeErr = portableRuntimeProbeWithClaudeIsolation(provider, path, isolateClaude)
	}
	ready := versionErr == nil && probeErr == nil && authReady && nativeServerStartable
	runtime := map[string]any{
		"kind":                    "external",
		"provider":                provider,
		"command":                 path,
		"identity_material":       path,
		"version":                 version,
		"version_detected":        versionErr == nil,
		"auth_ready":              authReady,
		"app_server_startable":    nativeServerStartable,
		"native_server_startable": nativeServerStartable,
		"ready":                   ready,
		"status":                  map[bool]string{true: "available", false: "unavailable"}[ready],
		"readiness_checked_at":    checkedAt.UnixMilli(),
		"readiness_valid_until":   checkedAt.Add(runtimeReadinessValidity).UnixMilli(),
		"protocol_versions":       []string{protocol},
		"transports":              transports,
	}
	if err := errors.Join(versionErr, probeErr); err != nil {
		runtime["last_error"] = err.Error()
	}
	if issue := portableRuntimeReadinessIssue(versionErr, probeErr); issue != "" {
		runtime["readiness_issue"] = issue
		runtime["readiness_message"] = portableRuntimeReadinessMessage(provider, issue)
	}
	if provider == "pi" || provider == "claude" {
		status := "unknown"
		switch {
		case errors.Is(probeErr, errRuntimeVerificationRequired):
			status = "configured"
		case errors.Is(probeErr, errRuntimeAuthenticationRequired):
			status = "unauthenticated"
		case authReady:
			status = "authenticated"
		}
		auth := map[string]any{"schema_version": 1, "status": status, "requires_openai_auth": false, "observed_at": checkedAt.UnixMilli()}
		var configured runtimeVerificationRequiredError
		if errors.As(probeErr, &configured) && (configured.backend == "openrouter" || provider == "claude" && configured.backend == "anthropic") {
			auth["backend"] = configured.backend
			runtime["model"] = configured.model
			runtime["model_provider"] = configured.backend
		}
		runtime["auth"] = auth
	}
	return runtime
}

func portableRuntimeReadinessMessage(provider, issue string) string {
	name := map[string]string{"pi": "Pi", "kimi": "Kimi", "claude": "Claude"}[provider]
	switch issue {
	case "verification_required":
		return name + " has local model configuration; verify provider access before dispatching work."
	case "authentication_required":
		if provider == "claude" {
			return "Claude reports no authenticated account."
		}
		return name + " reports no authenticated model."
	case "native_server_unavailable":
		return "The " + name + " native server could not complete its readiness handshake."
	default:
		return "The " + name + " runtime readiness probe failed."
	}
}

func portableRuntimeProbe(provider, path string) (bool, bool, error) {
	return portableRuntimeProbeWithClaudeIsolation(provider, path, false)
}

func portableRuntimeProbeWithClaudeIsolation(provider, path string, isolateClaude bool) (bool, bool, error) {
	switch provider {
	case "pi":
		return probePiRuntime(path)
	case "kimi":
		return probeKimiRuntime(path)
	case "claude":
		return probeClaudeRuntimeWithIsolation(path, isolateClaude)
	default:
		return false, false, fmt.Errorf("unsupported runtime probe provider %q", provider)
	}
}

func probeClaudeRuntime(path string) (bool, bool, error) {
	return probeClaudeRuntimeWithIsolation(path, false)
}

func probeClaudeRuntimeWithTimeout(path string, timeout time.Duration) (bool, bool, error) {
	return probeClaudeRuntimeWithIsolationAndTimeout(path, false, timeout)
}

func probeClaudeRuntimeWithIsolation(path string, isolateProfile bool) (bool, bool, error) {
	return probeClaudeRuntimeWithIsolationAndTimeout(path, isolateProfile, 10*time.Second)
}

func probeClaudeRuntimeWithIsolationAndTimeout(path string, isolateProfile bool, timeout time.Duration) (bool, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	profile, configuredBackend, configuredMethod, settingsErr := runtimeAuthClaudeProfileMethod()
	var settings []string
	if profile != "" {
		settings = []string{"--settings", profile}
	}
	if settingsErr != nil {
		return false, false, fmt.Errorf("%w: claude auth settings are invalid", errRuntimeProbeFailed)
	}
	args := append([]string{}, settings...)
	args = append(args, "auth", "status", "--json")
	cmd := commandContextWithProcessGroup(ctx, path, args...)
	isolateProfile = isolateProfile || len(settings) > 0
	cmd.Env = runtimeAuthClaudeExecEnv(map[string]any{"PATH": runtimeCommandPath(path)}, isolateProfile)
	cmd.WaitDelay = claudeCloseTimeout
	cmd.Stderr = io.Discard
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return false, false, fmt.Errorf("%w: claude auth status could not capture stdout", errRuntimeProbeFailed)
	}
	if err := cmd.Start(); err != nil {
		return false, false, fmt.Errorf("%w: claude auth status could not start", errRuntimeProbeFailed)
	}
	stdout, readErr := io.ReadAll(io.LimitReader(stdoutPipe, claudeAuthStatusMaxBytes+1))
	if len(stdout) > claudeAuthStatusMaxBytes {
		killProcessGroup(cmd)
		_ = cmd.Wait()
		return false, false, fmt.Errorf("%w: claude auth status exceeded the response bound", errRuntimeProbeFailed)
	}
	err = cmd.Wait()
	if ctx.Err() != nil {
		return false, false, fmt.Errorf("%w: claude auth status timed out", errRuntimeProbeFailed)
	}
	if readErr != nil {
		return false, false, fmt.Errorf("%w: claude auth status output failed", errRuntimeProbeFailed)
	}
	var status struct {
		LoggedIn   *bool  `json:"loggedIn"`
		AuthMethod string `json:"authMethod"`
	}
	if json.Unmarshal(stdout, &status) != nil || status.LoggedIn == nil {
		return false, false, fmt.Errorf("%w: claude auth status returned an invalid response", errRuntimeProbeFailed)
	}
	if !*status.LoggedIn {
		return false, true, fmt.Errorf("%w: claude has no authenticated account", errRuntimeAuthenticationRequired)
	}
	if err != nil {
		return false, true, fmt.Errorf("%w: claude auth status failed", errRuntimeProbeFailed)
	}
	// Claude's loggedIn includes locally configured API keys and bearer tokens.
	// Native startup and provider authentication remain separate observations.
	authReady := status.AuthMethod == "claude.ai"
	var authErr error
	switch status.AuthMethod {
	case "claude.ai":
	case "api_key", "oauth_token":
		if configuredBackend == "" {
			configuredBackend = claudeBackendFromEnvironment(status.AuthMethod)
			configuredMethod = status.AuthMethod
		}
	default:
		return false, false, fmt.Errorf("%w: claude authentication method unsupported", errRuntimeProbeFailed)
	}
	if configuredBackend != "" && status.AuthMethod != configuredMethod {
		return false, false, fmt.Errorf("%w: claude authentication profile did not take effect", errRuntimeProbeFailed)
	}
	model, err := probeClaudeStreamJSON(ctx, path, settings, isolateProfile)
	if err != nil {
		return authReady, false, errors.Join(authErr, fmt.Errorf("%w: claude stream-json initialize failed", errNativeServerUnavailable))
	}
	if !authReady {
		if configuredBackend != "" {
			authErr = runtimeVerificationRequiredError{backend: configuredBackend, model: model}
		} else {
			authErr = fmt.Errorf("%w: claude has local credential configuration", errRuntimeVerificationRequired)
		}
	}
	return authReady, true, authErr
}

func claudeBackendFromEnvironment(authMethod string) string {
	if authMethod == "api_key" && os.Getenv("ANTHROPIC_API_KEY") != "" && os.Getenv("ANTHROPIC_AUTH_TOKEN") == "" && os.Getenv("ANTHROPIC_BASE_URL") == "" {
		return "anthropic"
	}
	if authMethod == "oauth_token" && os.Getenv("ANTHROPIC_API_KEY") == "" && runtimeAuthCodexToken(os.Getenv("ANTHROPIC_AUTH_TOKEN")) && os.Getenv("ANTHROPIC_BASE_URL") == "https://openrouter.ai/api" {
		return "openrouter"
	}
	return ""
}

func probeClaudeStreamJSON(ctx context.Context, path string, settings []string, isolateProfile bool) (string, error) {
	nativeID, err := newClaudeSessionID()
	if err != nil {
		return "", err
	}
	workdir, err := os.MkdirTemp("", "salix-claude-readiness-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(workdir)

	args := append([]string{}, settings...)
	args = append(args,
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--replay-user-messages",
		"--permission-mode", "bypassPermissions",
		"--allow-dangerously-skip-permissions",
		"--session-id="+nativeID,
	)
	cmd := commandContextWithProcessGroup(ctx, path, args...)
	cmd.Dir = workdir
	cmd.Env = runtimeAuthClaudeExecEnv(map[string]any{"PATH": runtimeCommandPath(path)}, isolateProfile)
	cmd.WaitDelay = claudeCloseTimeout
	diagnostics := &claudeDiagnosticBuffer{}
	cmd.Stderr = diagnostics
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		return "", err
	}
	processDone := make(chan error, 1)
	go func() {
		processDone <- cmd.Wait()
		close(processDone)
	}()
	defer func() {
		_ = stdin.Close()
		killProcessGroup(cmd)
		select {
		case <-processDone:
		case <-time.After(externalRuntimeProbeTimeout):
		}
	}()

	request := map[string]any{
		"type": "control_request", "request_id": "salix-readiness",
		"request": map[string]any{"subtype": "initialize"},
	}
	raw, err := json.Marshal(request)
	if err != nil {
		return "", err
	}
	writeDone := make(chan error, 1)
	go func() {
		_, writeErr := stdin.Write(append(raw, '\n'))
		writeDone <- writeErr
	}()
	select {
	case err := <-writeDone:
		if err != nil {
			return "", errors.New("claude stream-json initialize write failed")
		}
	case <-ctx.Done():
		return "", ctx.Err()
	case <-processDone:
		return "", fmt.Errorf("claude process exited before initialize (%s)", diagnostics.category())
	}

	type initializeResult struct {
		model string
		err   error
	}
	response := make(chan initializeResult, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 64*1024), claudeReadinessMaxLineBytes)
		for scanner.Scan() {
			var message map[string]any
			if json.Unmarshal(scanner.Bytes(), &message) != nil {
				response <- initializeResult{err: errors.New("claude stream-json initialize returned invalid JSON")}
				return
			}
			if stringParam(message, "type") != "control_response" {
				continue
			}
			control := mapParam(message, "response")
			if stringParam(control, "request_id") != "salix-readiness" {
				continue
			}
			if stringParam(control, "subtype") != "success" {
				response <- initializeResult{err: errors.New("claude stream-json initialize was rejected")}
				return
			}
			model := ""
			models, _ := mapParam(control, "response")["models"].([]any)
			for _, item := range models {
				entry := mapParam(map[string]any{"entry": item}, "entry")
				if stringParam(entry, "value") == "default" {
					model = stringParam(entry, "resolvedModel")
					break
				}
			}
			if model != "" && !runtimeAuthCodexToken(model) {
				model = ""
			}
			response <- initializeResult{model: model}
			return
		}
		if scanner.Err() != nil {
			response <- initializeResult{err: errors.New("claude stream-json initialize exceeded its response bound")}
		} else {
			response <- initializeResult{err: errors.New("claude stream-json stdout closed before initialize")}
		}
	}()

	select {
	case result := <-response:
		return result.model, result.err
	case <-processDone:
		return "", fmt.Errorf("claude process exited before initialize (%s)", diagnostics.category())
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func probePiRuntime(path string) (bool, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	sessionDir, err := os.MkdirTemp("", "salix-pi-readiness-")
	if err != nil {
		return false, false, err
	}
	defer os.RemoveAll(sessionDir)

	cmd := exec.CommandContext(ctx, path, "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--session-dir", sessionDir)
	cmd.Dir = sessionDir
	cmd.Env = execEnv(map[string]any{"PATH": runtimeCommandPath(path)})
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return false, false, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return false, false, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return false, false, fmt.Errorf("%w: %v", errNativeServerUnavailable, err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	encoder := json.NewEncoder(stdin)
	if err := encoder.Encode(map[string]any{"id": "readiness-state", "type": "get_state"}); err != nil {
		return false, false, fmt.Errorf("%w: %v", errRuntimeProbeFailed, err)
	}
	responses := make(chan map[string]any, 2)
	decodeErr := make(chan error, 1)
	go func() {
		decoder := json.NewDecoder(stdout)
		matched := 0
		for matched < cap(responses) {
			var message map[string]any
			if err := decoder.Decode(&message); err != nil {
				decodeErr <- err
				return
			}
			if id := stringParam(message, "id"); id == "readiness-state" || id == "readiness-models" {
				responses <- message
				matched++
			}
		}
	}()

	select {
	case message := <-responses:
		if message["success"] != true || stringParam(mapParam(message, "data"), "sessionId") == "" {
			return false, true, fmt.Errorf("%w: pi state handshake was rejected", errRuntimeProbeFailed)
		}
		stateModel := mapParam(mapParam(message, "data"), "model")
		if err := encoder.Encode(map[string]any{"id": "readiness-models", "type": "get_available_models"}); err != nil {
			return false, true, fmt.Errorf("%w: %v", errRuntimeProbeFailed, err)
		}
		select {
		case modelsMessage := <-responses:
			if !piModelAvailable(stateModel, modelsMessage) {
				return false, true, fmt.Errorf("%w: pi has no configured active model", errRuntimeAuthenticationRequired)
			}
			// The native model list is local configuration, not provider evidence.
			return false, true, runtimeVerificationRequiredError{backend: stringParam(stateModel, "provider"), model: stringParam(stateModel, "id")}
		case err := <-decodeErr:
			return false, true, fmt.Errorf("%w: pi model handshake: %v", errRuntimeProbeFailed, err)
		case <-ctx.Done():
			return false, true, fmt.Errorf("%w: pi model handshake: %v", errRuntimeProbeFailed, ctx.Err())
		}
	case err := <-decodeErr:
		return false, false, fmt.Errorf("%w: pi state handshake: %v", errRuntimeProbeFailed, err)
	case <-ctx.Done():
		return false, false, fmt.Errorf("%w: pi state handshake: %v", errRuntimeProbeFailed, ctx.Err())
	}
}

func piModelAvailable(model map[string]any, response map[string]any) bool {
	if response["success"] != true {
		return false
	}
	provider, modelID := stringParam(model, "provider"), stringParam(model, "id")
	if provider == "" || modelID == "" || provider == "unknown" || modelID == "unknown" {
		return false
	}
	models, _ := mapParam(response, "data")["models"].([]any)
	for _, item := range models {
		candidate, _ := item.(map[string]any)
		if stringParam(candidate, "provider") == provider && stringParam(candidate, "id") == modelID {
			return true
		}
	}
	return false
}

func probeKimiRuntime(path string) (bool, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	home, err := os.MkdirTemp("", "salix-kimi-readiness-")
	if err != nil {
		return false, false, err
	}
	defer os.RemoveAll(home)
	if err := prepareKimiHome(home, sourceKimiHome(path), ""); err != nil {
		return false, false, err
	}
	port, err := reserveLocalPort()
	if err != nil {
		return false, false, err
	}
	cmd := exec.CommandContext(ctx, path, "web", "--no-open", "--port", strconv.Itoa(port), "--log-level", "error")
	cmd.Dir = home
	cmd.Env = execEnv(map[string]any{
		"KIMI_CODE_HOME":         home,
		"KIMI_DISABLE_TELEMETRY": "1",
		"PATH":                   runtimeCommandPath(path),
	})
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return false, false, fmt.Errorf("%w: %v", errNativeServerUnavailable, err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	session := &kimiRuntimeSession{
		baseURL: "http://127.0.0.1:" + strconv.Itoa(port),
		cmd:     cmd,
	}
	if err := session.waitReady(ctx, filepath.Join(home, "server.token")); err != nil {
		return false, false, fmt.Errorf("%w: %v", errNativeServerUnavailable, err)
	}
	auth, err := session.api(ctx, http.MethodGet, "/api/v1/auth", nil)
	if err != nil {
		return false, true, fmt.Errorf("%w: %v", errRuntimeProbeFailed, err)
	}
	if auth["ready"] != true || stringParam(auth, "default_model") == "" {
		return false, true, fmt.Errorf("%w: kimi native auth snapshot is not ready", errRuntimeAuthenticationRequired)
	}
	if managed := mapParam(auth, "managed_provider"); len(managed) != 0 && stringParam(managed, "status") != "authenticated" {
		return false, true, fmt.Errorf("%w: kimi managed provider is %s", errRuntimeAuthenticationRequired, defaultString(stringParam(managed, "status"), "not authenticated"))
	}
	created, err := session.api(ctx, "POST", "/api/v1/sessions", map[string]any{
		"metadata": map[string]any{"cwd": home},
		"agent_config": map[string]any{
			"model":           stringParam(auth, "default_model"),
			"permission_mode": "yolo",
		},
	})
	if err != nil {
		return false, true, fmt.Errorf("%w: %v", errRuntimeProbeFailed, err)
	}
	if stringParam(created, "id") == "" {
		return false, true, fmt.Errorf("%w: kimi readiness handshake returned no session id", errRuntimeProbeFailed)
	}
	return true, true, nil
}

func portableRuntimeReadinessIssue(versionErr, probeErr error) string {
	switch {
	case versionErr != nil:
		return "runtime_probe_failed"
	case errors.Is(probeErr, errRuntimeAuthenticationRequired):
		return "authentication_required"
	case errors.Is(probeErr, errRuntimeVerificationRequired):
		return "verification_required"
	case errors.Is(probeErr, errNativeServerUnavailable):
		return "native_server_unavailable"
	case probeErr != nil:
		return "runtime_probe_failed"
	default:
		return ""
	}
}

func detectCommands(name string, knownPaths []string) []string {
	paths := []string{}
	seen := map[string]bool{}
	for _, path := range managedRuntimeCommands(name) {
		paths = appendUniquePath(paths, seen, path)
	}
	if path, err := exec.LookPath(name); err == nil {
		paths = appendUniquePath(paths, seen, path)
	}
	for _, candidate := range knownPaths {
		if executable(candidate) {
			paths = appendUniquePath(paths, seen, candidate)
		}
	}
	return paths
}

func commandVersion(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "--version")
	cmd.Env = execEnv(map[string]any{"PATH": runtimeCommandPath(path)})
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func defaultKimiCommandPaths() []string {
	home, _ := os.UserHomeDir()
	return []string{filepath.Join(home, ".kimi-code", "bin", "kimi")}
}

func runtimeCommandPath(command string, prefixes ...string) string {
	dirs := make([]string, 0, len(prefixes)+4)
	seen := map[string]bool{}
	appendDir := func(dir string) {
		dir = strings.TrimSpace(dir)
		if dir == "" || seen[dir] {
			return
		}
		seen[dir] = true
		dirs = append(dirs, dir)
	}
	for _, dir := range prefixes {
		appendDir(dir)
	}
	if filepath.IsAbs(command) {
		appendDir(filepath.Dir(command))
	}
	if runtime.GOOS == "darwin" {
		appendDir("/opt/homebrew/bin")
		appendDir("/usr/local/bin")
	}
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		appendDir(dir)
	}
	return strings.Join(dirs, string(os.PathListSeparator))
}

func defaultClaudeCommandPaths() []string {
	home, _ := os.UserHomeDir()
	paths := []string{filepath.Join(home, ".local", "bin", "claude")}
	if runtime.GOOS == "darwin" {
		paths = append(paths, "/opt/homebrew/bin/claude", "/usr/local/bin/claude")
	}
	return paths
}
