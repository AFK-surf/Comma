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
	version, versionErr := "", error(nil)
	authReady, nativeServerStartable, probeErr := false, false, error(nil)
	if strings.TrimSpace(os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")) != "" && (provider == "claude" || provider == "pi") {
		version, versionErr, authReady, nativeServerStartable, probeErr = managedPortableReadiness(provider, path, isolateClaude)
	} else {
		version, versionErr = commandVersion(path)
		if versionErr == nil {
			authReady, nativeServerStartable, probeErr = portableRuntimeProbeWithClaudeIsolation(provider, path, isolateClaude)
		}
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

// The request has twenty seconds plus at most one three-second cleanup tail.
// Each native candidate has eight seconds; successful native startup is final.
func managedPortableReadiness(provider, command string, isolateClaude bool) (string, error, bool, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	selected := command
	authReady, startable, probeErr := false, false, error(nil)
	for _, candidate := range harnessLaunchCommands(provider, command) {
		selected = candidate
		attempt, stop := context.WithTimeout(ctx, 8*time.Second)
		if provider == "claude" {
			authReady, startable, probeErr = probeClaudeRuntimeContext(attempt, candidate, isolateClaude)
		} else {
			authReady, startable, probeErr = probePiRuntimeContext(attempt, candidate)
		}
		stop()
		if !canRetryHarnessStartup(ctx, probeErr) {
			break
		}
	}
	version, versionErr := readinessCommandVersion(ctx, selected)
	return version, versionErr, authReady, startable, probeErr
}

func readinessCommandVersion(ctx context.Context, command string) (string, error) {
	probe, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := commandContextWithProcessGroup(probe, command, "--version")
	cmd.Env, cmd.WaitDelay = execEnv(map[string]any{"PATH": runtimeCommandPath(command)}), claudeCloseTimeout
	cmd.Cancel = func() error { killHarnessStartupGroup(cmd); return nil }
	output := &harnessDiagnosticBuffer{}
	cmd.Stdout, cmd.Stderr = output, output
	err := cmd.Run()
	killHarnessStartupGroup(cmd)
	version := strings.TrimSpace(output.text())
	if err != nil {
		return "", errors.New("selected runtime version probe failed")
	}
	if version == "" {
		return "", errors.New("selected runtime version probe returned empty output")
	}
	return version, nil
}

// Only ephemeral readiness subprocesses use this cleanup. Join pipe users
// before Wait; a failed join never permits another candidate to start.
func finishReadinessProcess(ctx context.Context, cmd *exec.Cmd, stdin io.Closer, stdout io.Closer, joins ...<-chan struct{}) error {
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), claudeCloseTimeout)
	defer cancel()
	exited := make(chan struct{})
	_ = stdin.Close()
	killHarnessStartupGroup(cmd)
	_ = stdout.Close()
	go func() {
		for _, joined := range joins {
			<-joined
		}
		_ = cmd.Wait()
		close(exited)
	}()
	return stopExternalRuntime(cleanup, func() {}, exited)
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
	return probeClaudeRuntimeContext(ctx, path, isolateProfile)
}

func probeClaudeRuntimeContext(ctx context.Context, path string, isolateProfile bool) (bool, bool, error) {
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
	cmd.Cancel = func() error { killHarnessStartupGroup(cmd); return nil }
	diagnostics := &harnessDiagnosticBuffer{}
	cmd.Stderr = diagnostics
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return false, false, fmt.Errorf("%w: claude auth status could not capture stdout", errRuntimeProbeFailed)
	}
	if err := cmd.Start(); err != nil {
		return false, false, &harnessStartupError{fmt.Errorf("%w: claude auth status could not start", errRuntimeProbeFailed)}
	}
	defer killHarnessStartupGroup(cmd)
	stdout, readErr := io.ReadAll(io.LimitReader(stdoutPipe, claudeAuthStatusMaxBytes+1))
	if len(stdout) > claudeAuthStatusMaxBytes {
		killHarnessStartupGroup(cmd)
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
		failure := fmt.Errorf("%w: claude auth status returned an invalid response", errRuntimeProbeFailed)
		var exit *exec.ExitError
		bootstrap := errors.As(err, &exit) && (exit.ExitCode() == 126 || exit.ExitCode() == 127 || strings.Contains(diagnostics.text(), "MODULE_NOT_FOUND") || strings.Contains(diagnostics.text(), "ERR_MODULE_NOT_FOUND"))
		if bootstrap && diagnostics.permitsStartupRetry() {
			return false, false, &harnessStartupError{failure}
		}
		return false, false, failure
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
		return authReady, false, errors.Join(authErr, fmt.Errorf("%w: claude stream-json initialize failed: %w", errNativeServerUnavailable, err))
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

func probeClaudeStreamJSON(ctx context.Context, path string, settings []string, isolateProfile bool) (model string, probeErr error) {
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
	cmd.Cancel = func() error { killHarnessStartupGroup(cmd); return nil }
	diagnostics := &harnessDiagnosticBuffer{}
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
		return "", &harnessStartupError{errors.New("claude stream-json process could not start")}
	}
	var joins []<-chan struct{}
	defer func() {
		if err := finishReadinessProcess(ctx, cmd, stdin, stdout, joins...); err != nil {
			probeErr = err
			return
		}
		var startup *harnessStartupError
		if errors.As(probeErr, &startup) && !diagnostics.permitsStartupRetry() {
			probeErr = startup.error
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
	writerExited := make(chan struct{})
	joins = append(joins, writerExited)
	go func() {
		defer close(writerExited)
		_, writeErr := stdin.Write(append(raw, '\n'))
		writeDone <- writeErr
	}()
	select {
	case err := <-writeDone:
		if err != nil {
			return "", &harnessStartupError{errors.New("claude stream-json initialize write failed")}
		}
	case <-ctx.Done():
		return "", &harnessStartupError{errors.New("claude stream-json initialize timed out")}
	}

	type initializeResult struct {
		model string
		err   error
	}
	response := make(chan initializeResult, 1)
	readerExited := make(chan struct{})
	joins = append(joins, readerExited)
	go func() {
		defer close(readerExited)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 64*1024), claudeReadinessMaxLineBytes)
		for scanner.Scan() {
			var message map[string]any
			if json.Unmarshal(scanner.Bytes(), &message) != nil {
				response <- initializeResult{err: &harnessStartupError{errors.New("claude stream-json initialize returned invalid JSON")}}
				return
			}
			if native := stringParam(message, "session_id"); native != "" && native != nativeID {
				response <- initializeResult{err: &nativeControlRejection{errors.New("claude readiness session identity mismatch")}}
				return
			}
			if kind := stringParam(message, "type"); kind == "result" || kind == "error" {
				response <- initializeResult{err: &nativeControlRejection{errors.New("claude stream-json startup was refused")}}
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
				response <- initializeResult{err: &nativeControlRejection{errors.New("claude stream-json initialize was rejected")}}
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
			response <- initializeResult{err: &harnessStartupError{errors.New("claude stream-json initialize exceeded its response bound")}}
		} else {
			response <- initializeResult{err: &harnessStartupError{errors.New("claude stream-json stdout closed before initialize")}}
		}
	}()

	select {
	case result := <-response:
		return result.model, result.err
	case <-ctx.Done():
		return "", &harnessStartupError{errors.New("claude stream-json initialize timed out")}
	}
}

func probePiRuntime(path string) (bool, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return probePiRuntimeContext(ctx, path)
}

func probePiRuntimeContext(ctx context.Context, path string) (authReady, startable bool, probeErr error) {
	sessionDir, err := os.MkdirTemp("", "salix-pi-readiness-")
	if err != nil {
		return false, false, err
	}
	defer os.RemoveAll(sessionDir)
	cmd := commandContextWithProcessGroup(ctx, path, "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--session-dir", sessionDir)
	cmd.Dir, cmd.Env = sessionDir, execEnv(map[string]any{"PATH": runtimeCommandPath(path)})
	cmd.WaitDelay = claudeCloseTimeout
	cmd.Cancel = func() error { killHarnessStartupGroup(cmd); return nil }
	diagnostics := &harnessDiagnosticBuffer{}
	cmd.Stderr = diagnostics
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return false, false, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return false, false, err
	}
	if err := cmd.Start(); err != nil {
		return false, false, &harnessStartupError{fmt.Errorf("%w: pi process could not start", errNativeServerUnavailable)}
	}
	var joins []<-chan struct{}
	defer func() {
		if err := finishReadinessProcess(ctx, cmd, stdin, stdout, joins...); err != nil {
			probeErr = err
			return
		}
		var startup *harnessStartupError
		if errors.As(probeErr, &startup) && !diagnostics.permitsStartupRetry() {
			probeErr = startup.error
		}
	}()
	replies := make(chan piReadinessReply, 1)
	readerContext, stopReader := context.WithCancel(ctx)
	defer stopReader()
	readerExited := make(chan struct{})
	joins = append(joins, readerExited)
	go func() {
		defer close(readerExited)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 64*1024), claudeReadinessMaxLineBytes)
		for scanner.Scan() {
			var message map[string]any
			if json.Unmarshal(scanner.Bytes(), &message) != nil {
				select {
				case replies <- piReadinessReply{err: errors.New("pi returned invalid readiness JSON")}:
				case <-readerContext.Done():
				}
				return
			}
			select {
			case replies <- piReadinessReply{message: message}:
			case <-readerContext.Done():
				return
			}
		}
		select {
		case replies <- piReadinessReply{err: errors.New("pi readiness stream closed or exceeded its response bound")}:
		case <-readerContext.Done():
		}
	}()
	encoder := json.NewEncoder(stdin)
	if err := encoder.Encode(map[string]any{"id": "readiness-state", "type": "get_state"}); err != nil {
		return false, false, &harnessStartupError{fmt.Errorf("%w: pi state request failed", errRuntimeProbeFailed)}
	}
	state, err := readPiReadinessReply(ctx, replies, "readiness-state")
	if err != nil {
		return false, false, &harnessStartupError{fmt.Errorf("%w: pi state handshake failed", errRuntimeProbeFailed)}
	}
	if state["success"] == false {
		return false, true, &nativeControlRejection{fmt.Errorf("%w: pi state handshake was rejected", errRuntimeProbeFailed)}
	}
	if state["success"] != true || stringParam(mapParam(state, "data"), "sessionId") == "" {
		return false, false, &harnessStartupError{fmt.Errorf("%w: pi state handshake was invalid", errRuntimeProbeFailed)}
	}
	stateModel := mapParam(mapParam(state, "data"), "model")
	if err := encoder.Encode(map[string]any{"id": "readiness-models", "type": "get_available_models"}); err != nil {
		return false, true, fmt.Errorf("%w: pi model request failed", errRuntimeProbeFailed)
	}
	models, err := readPiReadinessReply(ctx, replies, "readiness-models")
	if err != nil {
		return false, true, fmt.Errorf("%w: pi model handshake failed", errRuntimeProbeFailed)
	}
	if !piModelAvailable(stateModel, models) {
		return false, true, fmt.Errorf("%w: pi has no configured active model", errRuntimeAuthenticationRequired)
	}
	// Local configuration never proves provider authentication.
	return false, true, runtimeVerificationRequiredError{backend: stringParam(stateModel, "provider"), model: stringParam(stateModel, "id")}
}

type piReadinessReply struct {
	message map[string]any
	err     error
}

func readPiReadinessReply(ctx context.Context, replies <-chan piReadinessReply, id string) (map[string]any, error) {
	for {
		select {
		case reply := <-replies:
			if reply.err != nil {
				return nil, reply.err
			}
			if stringParam(reply.message, "id") == id {
				return reply.message, nil
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
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
