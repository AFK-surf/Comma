package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type harnessDiagnosticBuffer struct {
	mu   sync.Mutex
	data []byte
}

func (b *harnessDiagnosticBuffer) text() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.data)
}

func (b *harnessDiagnosticBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if remaining := claudeDiagnosticMaxBytes - len(b.data); remaining > 0 {
		b.data = append(b.data, p[:min(len(p), remaining)]...)
	}
	return len(p), nil
}

func (b *harnessDiagnosticBuffer) category() string {
	if b == nil {
		return "runtime_failed"
	}
	b.mu.Lock()
	text := strings.ToLower(string(b.data))
	b.mu.Unlock()
	switch {
	case strings.Contains(text, "usage limit"), strings.Contains(text, "quota"), strings.Contains(text, "credit balance"):
		return "quota_exhausted"
	case strings.Contains(text, "rate limit"), strings.Contains(text, "too many requests"):
		return "rate_limited"
	case strings.Contains(text, "not logged in"), strings.Contains(text, "authentication"), strings.Contains(text, "please login"), strings.Contains(text, "invalid api key"), strings.Contains(text, "unauthorized"), strings.Contains(text, "invalid token"):
		return "authentication_required"
	case strings.Contains(text, "configuration"), strings.Contains(text, "invalid model"), strings.Contains(text, "model not found"), strings.Contains(text, "model unavailable"):
		return "configuration_invalid"
	case strings.Contains(text, "stream-json"), strings.Contains(text, "unknown option"), strings.Contains(text, "unexpected argument"):
		return "unsupported_stream_json"
	default:
		return "runtime_failed"
	}
}

var imageHarnessCommand = func(provider string) string {
	return filepath.Join("/opt/salix/default-harness/bin", provider)
}

// Launch paths do not change Device runtime or credential identity.
func harnessLaunchCommands(provider, command string) []string {
	candidates := []string{command}
	if strings.TrimSpace(os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")) == "" {
		return candidates
	}
	fallback := imageHarnessCommand(provider)
	if command != fallback && executable(fallback) {
		candidates = append(candidates, fallback)
	}
	return candidates
}

type nativeControlRejection struct{ error }

func (e *nativeControlRejection) Unwrap() error { return e.error }

type harnessStartupError struct{ error }

func (e *harnessStartupError) Unwrap() error { return e.error }

type codexStartupNormalExit struct{ error }

func (e *codexStartupNormalExit) Unwrap() error { return e.error }

// Version evidence belongs to the selected generation. A compatibility probe
// cannot replace an initialized process or grant authentication readiness.
func (r *codexRuntime) readinessVersion(ctx context.Context) (string, bool, string) {
	r.initMu.Lock()
	defer r.initMu.Unlock()
	if r.versionObserved {
		return defaultString(r.nativeVersion, "unknown"), r.versionError == "", r.versionError
	}
	r.versionObserved = true
	if r.nativeVersion != "" {
		return r.nativeVersion, true, ""
	}
	probeCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := commandContextWithProcessGroup(probeCtx, r.cmd.Path, "--version")
	cmd.Env, cmd.Dir = r.cmd.Env, r.cmd.Dir
	cmd.WaitDelay = claudeCloseTimeout
	output := &harnessDiagnosticBuffer{}
	cmd.Stdout, cmd.Stderr = output, output
	err := cmd.Run()
	killHarnessStartupGroup(cmd)
	r.nativeVersion = strings.TrimSpace(output.text())
	if err != nil {
		r.versionError = "version check failed"
	} else if r.nativeVersion == "" {
		r.versionError = "version check returned empty output"
	}
	return defaultString(r.nativeVersion, "unknown"), r.versionError == "", r.versionError
}

func canRetryHarnessStartup(ctx context.Context, err error) bool {
	var startup *harnessStartupError
	return ctx.Err() == nil && errors.As(err, &startup)
}

// Failed candidates must exit before another process can own the same target.
func stopHarnessStartup(ctx context.Context, stop func(), exited <-chan struct{}) error {
	cleanup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return stopExternalRuntime(cleanup, stop, exited)
}

func (i *codexRuntimeImplementation) ensureCodexRuntime(ctx context.Context, command string) (*codexRuntime, error) {
	if err := lockRuntimeContext(ctx, &i.startupMu); err != nil {
		return nil, err
	}
	defer i.startupMu.Unlock()
	i.mu.Lock()
	if i.closed {
		i.mu.Unlock()
		return nil, errCodexAppServerUnavailable
	}
	existing := i.runtimes[command]
	if existing != nil && existing.isRunning() {
		quarantined := i.authQuarantined[existing.generation]
		i.mu.Unlock()
		if quarantined {
			return nil, errCodexAuthGenerationQuarantined
		}
		return existing, nil
	}
	i.mu.Unlock()
	bridgeURL, err := i.connector.ensureRuntimeBridge()
	if err != nil {
		return nil, err
	}
	for _, launchCommand := range harnessLaunchCommands("codex", command) {
		native, startErr := i.startRuntimeCommand(externalRuntimeInput{command: command}, bridgeURL, "", launchCommand)
		if startErr != nil {
			err = startErr
			if !canRetryHarnessStartup(ctx, err) {
				return nil, err
			}
			continue
		}
		i.mu.Lock()
		if i.closed {
			i.mu.Unlock()
			native.start()
			_ = stopHarnessStartup(context.WithoutCancel(ctx), func() { killHarnessStartupGroup(native.cmd); native.terminate() }, native.exited)
			return nil, errCodexAppServerUnavailable
		}
		i.runtimes[command] = native
		i.mu.Unlock()
		native.start()
		err = native.connect(ctx)
		if err == nil {
			err = native.ensureInitialized(ctx)
		}
		if err == nil {
			return native, nil
		}
		var rejection *codexRPCError
		if errors.As(err, &rejection) {
			return native, err
		}
		// Preserve the existing cmd.Wait success lifecycle. Sample the exit
		// before this attempt kills a process that has not exited.
		select {
		case <-native.exited:
			if native.cmd.ProcessState != nil && native.cmd.ProcessState.Success() {
				killHarnessStartupGroup(native.cmd)
				return native, &codexStartupNormalExit{err}
			}
		default:
		}
		i.retireUnusableRuntimeGeneration(native)
		// Auth callers hold the target lock. finish needs that lock before done.
		if cleanupErr := stopHarnessStartup(context.WithoutCancel(ctx), func() { killHarnessStartupGroup(native.cmd); native.terminate() }, native.exited); cleanupErr != nil {
			return nil, cleanupErr
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if !native.diagnostics.permitsStartupRetry() {
			return nil, err
		}
	}
	return nil, err
}

func (b *harnessDiagnosticBuffer) permitsStartupRetry() bool {
	category := b.category()
	return category == "runtime_failed" || category == "unsupported_stream_json"
}

// Startup candidates have accepted no business input. Their whole process
// group belongs to this attempt, including children of an exited wrapper.
func killHarnessStartupGroup(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}
