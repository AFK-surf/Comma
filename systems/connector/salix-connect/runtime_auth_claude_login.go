package main

import (
	"context"
	"errors"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	runtimeAuthClaudeLoginFlow    = "authorization_code"
	runtimeAuthClaudeLoginTimeout = 15 * time.Minute
	runtimeAuthClaudeExchangeWait = 20 * time.Second
)

type runtimeAuthClaudeLoginOutput struct {
	mu    sync.Mutex
	data  []byte
	ready chan struct{}
	once  sync.Once
}

func (w *runtimeAuthClaudeLoginOutput) Write(p []byte) (int, error) {
	w.mu.Lock()
	if remaining := runtimeAuthEnvelopeLimit - len(w.data); remaining > 0 {
		w.data = append(w.data, p[:min(len(p), remaining)]...)
		if _, ok := runtimeAuthClaudeAuthorizationURL(w.data); ok {
			w.once.Do(func() { close(w.ready) })
		}
	}
	w.mu.Unlock()
	return len(p), nil
}

func (w *runtimeAuthClaudeLoginOutput) authorizationURL() (string, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return runtimeAuthClaudeAuthorizationURL(w.data)
}

func (w *runtimeAuthClaudeLoginOutput) issue(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "provider_unavailable"
	}
	w.mu.Lock()
	text := strings.ToLower(string(w.data))
	w.mu.Unlock()
	switch {
	case strings.Contains(text, "invalid code"), strings.Contains(text, "expired code"), strings.Contains(text, "authorization code is invalid"):
		return "credentials_rejected"
	case strings.Contains(text, "rate limit"), strings.Contains(text, "too many requests"):
		return "rate_limited"
	case strings.Contains(text, "network"), strings.Contains(text, "connection"), strings.Contains(text, "timed out"):
		return "provider_unavailable"
	default:
		return "native_helper_failed"
	}
}

type runtimeAuthClaudeLogin struct {
	cancel      context.CancelFunc
	cmd         *exec.Cmd
	stdin       io.WriteCloser
	done        chan struct{}
	waitMu      sync.Mutex
	waitErr     error
	directory   string
	credentials string
	output      *runtimeAuthClaudeLoginOutput
	closeOnce   sync.Once
}

func startRuntimeAuthClaudeLogin(ctx context.Context, command string, carrier *runtimeTransport) (*runtimeAuthClaudeLogin, string, error) {
	if carrier == nil || strings.TrimSpace(command) == "" {
		return nil, "", errRuntimeAuthInputInvalid
	}
	directory, err := os.MkdirTemp("", "salix-claude-login-")
	if err != nil {
		return nil, "", err
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		os.RemoveAll(directory)
		return nil, "", err
	}
	loginCtx, cancel := context.WithTimeout(context.Background(), runtimeAuthClaudeLoginTimeout)
	output := &runtimeAuthClaudeLoginOutput{ready: make(chan struct{})}
	cmd := commandContextWithProcessGroup(loginCtx, command, "auth", "login", "--claudeai")
	cmd.Env = runtimeAuthClaudeLoginEnvironment(directory)
	cmd.Stdout, cmd.Stderr = output, output
	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		os.RemoveAll(directory)
		return nil, "", err
	}
	if err := cmd.Start(); err != nil {
		stdin.Close()
		cancel()
		os.RemoveAll(directory)
		return nil, "", err
	}
	login := &runtimeAuthClaudeLogin{
		cancel: cancel, cmd: cmd, stdin: stdin, done: make(chan struct{}), directory: directory,
		credentials: filepath.Join(directory, ".claude", runtimeAuthClaudeCredentialsName), output: output,
	}
	go func() {
		err := cmd.Wait()
		login.waitMu.Lock()
		login.waitErr = err
		login.waitMu.Unlock()
		close(login.done)
	}()
	go func() {
		select {
		case <-carrier.done:
			login.close()
		case <-loginCtx.Done():
		}
	}()
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case <-output.ready:
		if authorizationURL, ok := output.authorizationURL(); ok {
			return login, authorizationURL, nil
		}
	case <-login.done:
		login.close()
		return nil, "", errors.Join(errors.New("claude login exited before authorization"), login.processError())
	case <-ctx.Done():
	case <-timer.C:
	}
	login.close()
	return nil, "", errors.New("claude login did not provide an authorization URL")
}

func (login *runtimeAuthClaudeLogin) submit(ctx context.Context, code []byte) ([]byte, error) {
	if login == nil || !validRuntimeAuthClaudeCode(code) {
		return nil, errRuntimeAuthInputInvalid
	}
	line := make([]byte, len(code)+1)
	copy(line, code)
	line[len(code)] = '\n'
	defer clear(line)
	if _, err := login.stdin.Write(line); err != nil {
		return nil, err
	}
	if err := login.stdin.Close(); err != nil {
		return nil, err
	}
	timer := time.NewTimer(runtimeAuthClaudeExchangeWait)
	defer timer.Stop()
	select {
	case <-login.done:
		if err := login.processError(); err != nil {
			return nil, err
		}
	case <-ctx.Done():
		login.close()
		return nil, ctx.Err()
	case <-timer.C:
		login.close()
		return nil, context.DeadlineExceeded
	}
	file, err := os.Open(login.credentials)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > runtimeAuthPlaintextLimit {
		return nil, errRuntimeAuthInputInvalid
	}
	data, err := io.ReadAll(io.LimitReader(file, runtimeAuthPlaintextLimit+1))
	if err != nil || len(data) > runtimeAuthPlaintextLimit || parseRuntimeAuthClaudeCredentials(data) != nil {
		clear(data)
		return nil, errRuntimeAuthInputInvalid
	}
	return data, nil
}

func (login *runtimeAuthClaudeLogin) processError() error {
	login.waitMu.Lock()
	defer login.waitMu.Unlock()
	return login.waitErr
}

func (login *runtimeAuthClaudeLogin) close() {
	if login == nil {
		return
	}
	login.closeOnce.Do(func() {
		login.cancel()
		login.stdin.Close()
		go func() {
			select {
			case <-login.done:
			case <-time.After(runtimeAuthNativeCancelTimeout):
				killProcessGroup(login.cmd)
			}
			os.RemoveAll(login.directory)
		}()
	})
}

func runtimeAuthClaudeLoginEnvironment(directory string) []string {
	blocked := map[string]bool{
		"HOME": true, "CLAUDE_CONFIG_DIR": true, "BROWSER": true,
		"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true, "ANTHROPIC_BASE_URL": true,
		"CLAUDE_CODE_OAUTH_TOKEN": true,
	}
	environment := make([]string, 0, len(os.Environ())+3)
	for _, item := range os.Environ() {
		name, _, _ := strings.Cut(item, "=")
		if !blocked[name] {
			environment = append(environment, item)
		}
	}
	return append(environment, "HOME="+directory, "CLAUDE_CONFIG_DIR="+filepath.Join(directory, ".claude"), "BROWSER=true")
}

func validRuntimeAuthClaudeCode(code []byte) bool {
	if len(code) == 0 || len(code) > 4096 || strings.TrimSpace(string(code)) != string(code) {
		return false
	}
	for _, value := range string(code) {
		if unicode.IsSpace(value) || unicode.IsControl(value) {
			return false
		}
	}
	return true
}

func runtimeAuthClaudeAuthorizationURL(data []byte) (string, bool) {
	const prefix = "https://claude.com/cai/oauth/authorize?"
	start := strings.Index(string(data), prefix)
	if start < 0 {
		return "", false
	}
	value := string(data[start:])
	if end := strings.IndexFunc(value, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }); end >= 0 {
		value = value[:end]
	}
	if len(value) > 4096 {
		return "", false
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host != "claude.com" || parsed.Path != "/cai/oauth/authorize" || parsed.Fragment != "" {
		return "", false
	}
	query := parsed.Query()
	allowed := map[string]bool{"code": true, "client_id": true, "response_type": true, "redirect_uri": true, "scope": true, "code_challenge": true, "code_challenge_method": true, "state": true}
	if len(query) != len(allowed) {
		return "", false
	}
	for name, values := range query {
		if !allowed[name] || len(values) != 1 || values[0] == "" {
			return "", false
		}
	}
	if query.Get("code") != "true" || query.Get("response_type") != "code" ||
		query.Get("redirect_uri") != "https://platform.claude.com/oauth/code/callback" ||
		query.Get("code_challenge_method") != "S256" || !runtimeAuthCodexToken(query.Get("client_id")) ||
		!runtimeAuthCodexToken(query.Get("code_challenge")) || !runtimeAuthCodexToken(query.Get("state")) {
		return "", false
	}
	return value, true
}

func (m *runtimeAuthCoordinator) startPrivateClaudeLogin(ctx context.Context, target runtimeProbeTarget, binding runtimeAuthInputContext, local *runtimeAuthPrivateTarget) (map[string]any, error) {
	attempt, err := m.beginPrivateInput(target, binding)
	if err != nil {
		return nil, err
	}
	current := func() bool { return m.codex.connector.privateRuntimeAuthCurrent(ctx, local, binding) }
	unlock := m.lockTarget(target.key())
	if m.attempt(target.key()) != attempt || !current() || m.targetBusy(target) {
		m.removeAttemptIfCurrent(target.key(), attempt)
		unlock()
		return nil, errors.New("runtime_busy")
	}
	attempt.target = local
	attempt.input.phase = "receiving"
	unlock()

	login, authorizationURL, err := startRuntimeAuthClaudeLogin(ctx, target.identityMaterial, local.carrier)
	if err != nil {
		unlock = m.lockTarget(target.key())
		m.removeAttemptIfCurrent(target.key(), attempt)
		unlock()
		return nil, errors.New("native auth unavailable")
	}
	unlock = m.lockTarget(target.key())
	defer unlock()
	if m.attempt(target.key()) != attempt || !current() {
		login.close()
		m.removeAttemptIfCurrent(target.key(), attempt)
		return nil, errors.New("runtime auth target changed")
	}
	attempt.input.claudeLogin = login
	attempt.input.verificationURL = authorizationURL
	attempt.input.phase = "awaiting_user"
	return map[string]any{
		"context": attempt.input.context, "public_key": attempt.input.publicKey,
		"phase": "awaiting_user", "save_result": "not_committed", "verification_url": authorizationURL,
	}, nil
}

func (m *runtimeAuthCoordinator) submitPrivateClaudeLogin(ctx context.Context, target runtimeProbeTarget, attempt *runtimeAuthAttempt, expected runtimeAuthInputContext, envelope runtimeAuthInputEnvelope, implementation *claudeRuntimeImplementation, authPath string, current func() bool, withCarrier func(func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	rejected := runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	unlock := m.lockTarget(target.key())
	if attempt == nil || attempt.input == nil || attempt.input.context != expected || attempt.input.phase != "awaiting_user" ||
		attempt.input.claudeLogin == nil || implementation == nil || withCarrier == nil || current == nil || !current() ||
		attempt.expiresAt <= m.now().UnixMilli() {
		unlock()
		return rejected
	}
	input := attempt.input
	input.phase = "receiving"
	aad, err := expected.aad()
	var plaintext []byte
	if err == nil {
		plaintext, err = input.key.open(envelope, aad)
	}
	input.key.destroy()
	if err != nil || !validRuntimeAuthClaudeCode(plaintext) {
		clear(plaintext)
		input.phase = "failed"
		input.outcome = runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
		unlock()
		return input.outcome
	}
	input.phase = "applying"
	input.outcome = runtimeAuthSaveOutcome{SaveResult: "unknown", Issue: "applying"}
	login := input.claudeLogin
	unlock()
	data, err := login.submit(ctx, plaintext)
	clear(plaintext)
	login.close()
	if err != nil {
		unlock = m.lockTarget(target.key())
		defer unlock()
		if m.attempt(target.key()) == attempt && input.phase == "applying" {
			input.phase = "failed"
			issue := login.output.issue(err)
			if ctx.Err() != nil || !current() {
				issue = "target_changed"
			}
			input.outcome = runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: issue}
		}
		return input.outcome
	}
	defer clear(data)
	result := saveRuntimeAuthClaudeCredentials(ctx, authPath, data, func(stage string) runtimeAuthSaveOutcome {
		unlock := m.lockTarget(target.key())
		defer unlock()
		if m.attempt(target.key()) != attempt || input.phase != "applying" || attempt.expiresAt <= m.now().UnixMilli() || !current() {
			return rejected
		}
		if m.targetBusy(target) {
			return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "runtime_busy"}
		}
		m.codex.connector.runtimeInventory.updateAuthSnapshot(target, map[string]any{
			"schema_version": 1, "status": "unknown", "requires_openai_auth": false, "observed_at": m.now().UnixMilli(),
		}, false)
		input.outcome = implementation.commitAuthSettings(ctx, expected.NativeGeneration, expected.AuthEpoch, func() runtimeAuthSaveOutcome {
			return withCarrier(func() runtimeAuthSaveOutcome {
				return commitRuntimeAuthClaudeCredentials(ctx, stage, authPath)
			})
		})
		return input.outcome
	})
	unlock = m.lockTarget(target.key())
	defer unlock()
	if m.attempt(target.key()) == attempt && input.phase == "applying" {
		input.outcome = result
		input.phase = "failed"
		if result.SaveResult == "committed" {
			input.phase = "completed"
			if current() {
				m.codex.connector.runtimeInventory.updateAuthSnapshot(target, map[string]any{
					"schema_version": 1, "status": "configured", "requires_openai_auth": false,
					"observed_at": m.now().UnixMilli(), "backend": "anthropic",
				}, false)
			}
		}
		if result.SaveResult == "unknown" {
			input.phase = "outcome_unknown"
		}
	}
	return result
}
