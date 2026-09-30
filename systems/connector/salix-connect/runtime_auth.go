package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// runtimeAuthNativeOutcomeUnknownError means a native auth mutation may have
// started but no terminal result proved that it stopped. Callers that own a
// Host execution right must retain it until later terminal evidence or an exact
// instance stop settles the operation.
type runtimeAuthNativeOutcomeUnknownError struct {
	cause error
}

func (e *runtimeAuthNativeOutcomeUnknownError) Error() string {
	return "runtime auth native operation outcome is unknown; action required: " + e.cause.Error()
}

func (e *runtimeAuthNativeOutcomeUnknownError) Unwrap() error { return e.cause }

func runtimeAuthNativeOutcomeUnknown(err error) bool {
	var unknown *runtimeAuthNativeOutcomeUnknownError
	return errors.As(err, &unknown)
}

func runtimeAuthUnknown(cause error) error {
	return &runtimeAuthNativeOutcomeUnknownError{cause: cause}
}

const (
	runtimeAuthConcurrency              = 2
	runtimeAuthFlowDeviceCode           = "device_code"
	codexDeviceCodeAttemptTTL           = 15 * time.Minute
	runtimeAuthNativeCancelTimeout      = 5 * time.Second
	runtimeAuthNotificationReadTimeout  = 15 * time.Second
	runtimeAuthNotificationProbeTimeout = 25 * time.Second
)

var errCodexAuthGenerationQuarantined = errors.New("codex auth generation is quarantined")

type runtimeAuthAttempt struct {
	input              *runtimeAuthPrivateInput
	probeTarget        runtimeProbeTarget
	scope              *runtimeAuthInputContext
	target             *runtimeAuthPrivateTarget
	attemptID          string
	flow               string
	nativeLoginID      string
	verificationURL    string
	userCode           string
	expiresAt          int64
	runtime            *codexRuntime
	runtimeGeneration  string
	completionObserved bool
}

type codexAuthCompletion struct {
	loginID string
	success bool
	valid   bool
}

type codexAuthNotificationState struct {
	runtime        *codexRuntime
	running        bool
	accountUpdated bool
	completion     *codexAuthCompletion
}

type runtimeAuthTargetLock struct {
	mutex       sync.Mutex
	users       int
	nativeCalls int
}

// One target owner serializes native ceremonies and private file commits.
// RuntimeAuth.tla covers native login fencing; RuntimeAuthInput.tla covers
// private input consumption and the final commit section.
type runtimeAuthCoordinator struct {
	codex *codexRuntimeImplementation

	mu                       sync.Mutex
	attempts                 map[string]*runtimeAuthAttempt
	verifications            map[string]runtimeAuthVerificationObservation
	locks                    map[string]*runtimeAuthTargetLock
	subscriptionRevisions    map[string]int64
	managedCredentials       map[string]*managedRuntimeCredential
	notifications            map[string]*codexAuthNotificationState
	now                      func() time.Time
	ttl                      time.Duration
	startTimeout             time.Duration
	cancelTimeout            time.Duration
	nativeCancelTimeout      time.Duration
	beforePendingPublication func()
}

func newRuntimeAuthCoordinator(codex *codexRuntimeImplementation) *runtimeAuthCoordinator {
	return &runtimeAuthCoordinator{
		codex:                 codex,
		attempts:              map[string]*runtimeAuthAttempt{},
		verifications:         map[string]runtimeAuthVerificationObservation{},
		locks:                 map[string]*runtimeAuthTargetLock{},
		subscriptionRevisions: map[string]int64{},
		managedCredentials:    map[string]*managedRuntimeCredential{},
		notifications:         map[string]*codexAuthNotificationState{},
		now:                   time.Now,
		ttl:                   codexDeviceCodeAttemptTTL,
		startTimeout:          15 * time.Second,
		cancelTimeout:         10 * time.Second,
		nativeCancelTimeout:   runtimeAuthNativeCancelTimeout,
	}
}

func runtimeAuthAvailable(runtimes []map[string]any) bool {
	for _, runtime := range runtimes {
		if stringParam(runtime, "kind") == "external" &&
			computeExternalRuntimeProvider(stringParam(runtime, "provider")) &&
			strings.TrimSpace(stringParam(runtime, "identity_material")) != "" {
			return true
		}
	}
	return false
}

func (c *connector) methodRuntimeAuthRead(ctx context.Context, params map[string]any) (map[string]any, error) {
	if err := c.acquireRuntimeAuth(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.runtimeAuthSlots }()
	return c.runtimeAuthReadAdmitted(ctx, params)
}

func (c *connector) runtimeAuthReadAdmitted(ctx context.Context, params map[string]any) (map[string]any, error) {
	target, err := c.runtimeAuthTarget(params, "provider", "identity_material")
	if err != nil {
		return nil, err
	}
	return c.runtimeAuthCoordinator().read(ctx, target)
}

func (c *connector) methodRuntimeAuthLoginStart(ctx context.Context, params map[string]any) (map[string]any, error) {
	if err := c.acquireRuntimeAuth(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.runtimeAuthSlots }()
	return c.runtimeAuthLoginStartAdmitted(ctx, params)
}

func (c *connector) runtimeAuthLoginStartAdmitted(ctx context.Context, params map[string]any) (map[string]any, error) {
	target, err := c.runtimeAuthTarget(params, "provider", "identity_material", "flow")
	if err != nil {
		return nil, err
	}
	flow, ok := params["flow"].(string)
	if !ok || strings.TrimSpace(flow) == "" || len(flow) > 64 {
		return nil, errors.New("runtime auth flow is unsupported")
	}
	return c.runtimeAuthCoordinator().start(ctx, target, flow)
}

func (c *connector) methodRuntimeAuthLoginCancel(ctx context.Context, params map[string]any) (map[string]any, error) {
	if err := c.acquireRuntimeAuth(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.runtimeAuthSlots }()
	return c.runtimeAuthLoginCancelAdmitted(ctx, params)
}

func (c *connector) runtimeAuthLoginCancelAdmitted(ctx context.Context, params map[string]any) (map[string]any, error) {
	target, err := c.runtimeAuthTarget(params, "provider", "identity_material", "attempt_id")
	if err != nil {
		return nil, err
	}
	attemptID, ok := params["attempt_id"].(string)
	if !ok || strings.TrimSpace(attemptID) == "" || len(attemptID) > 128 {
		return nil, errors.New("runtime auth attempt_id is invalid")
	}
	return c.runtimeAuthCoordinator().cancel(ctx, target, attemptID)
}

func (c *connector) runtimeAuthTarget(params map[string]any, allowedKeys ...string) (runtimeProbeTarget, error) {
	allowed := make(map[string]bool, len(allowedKeys))
	for _, key := range allowedKeys {
		allowed[key] = true
	}
	for key := range params {
		if !allowed[key] {
			return runtimeProbeTarget{}, fmt.Errorf("runtime auth parameter %q is not allowed", key)
		}
	}
	provider, providerOK := params["provider"].(string)
	identityMaterial, identityOK := params["identity_material"].(string)
	provider = strings.TrimSpace(provider)
	identityMaterial = strings.TrimSpace(identityMaterial)
	if !providerOK || !identityOK || provider == "" || identityMaterial == "" {
		return runtimeProbeTarget{}, errors.New("runtime auth requires provider and identity_material")
	}
	if provider != "codex" {
		return runtimeProbeTarget{}, errors.New("runtime auth provider is unsupported")
	}
	target, present := c.runtimeInventory.target(provider, identityMaterial)
	if !present {
		return runtimeProbeTarget{}, errors.New("runtime auth target changed or is not present in the current inventory")
	}
	return target, nil
}

func (c *connector) acquireRuntimeAuth(ctx context.Context) error {
	select {
	case c.runtimeAuthSlots <- struct{}{}:
		return nil
	default:
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			return errors.New("runtime auth capacity exhausted")
		}
	}
}

func (c *connector) runtimeAuthCoordinator() *runtimeAuthCoordinator {
	implementation, _ := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	if implementation == nil {
		return nil
	}
	return implementation.auth
}

func (m *runtimeAuthCoordinator) read(ctx context.Context, target runtimeProbeTarget) (map[string]any, error) {
	unlock := m.lockTarget(target.key())
	defer unlock()

	if expired := m.takeExpiredAttempt(target.key()); expired != nil {
		snapshot := m.retireExpiredAttempt(target, expired)
		return map[string]any{"auth": snapshot}, nil
	}

	runtime, snapshot, err := m.codex.readRuntimeAuthSnapshot(ctx, target)
	if err != nil {
		snapshot = codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli())
		m.publishSnapshotForRuntime(target, runtime, snapshot)
		return map[string]any{"auth": snapshot}, nil
	}

	attempt := m.attempt(target.key())
	if attempt != nil && attempt.input != nil {
		attempt = nil
	}
	if !m.codex.currentRuntime(runtime) {
		if attempt != nil && m.removeAttemptIfCurrent(target.key(), attempt) {
			m.cancelNativeBestEffort(attempt)
		}
		snapshot = codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli())
		return map[string]any{"auth": snapshot}, nil
	}
	if attempt != nil &&
		(attempt.runtime != runtime || attempt.runtimeGeneration != runtime.generation) {
		if m.removeAttemptIfCurrent(target.key(), attempt) {
			m.cancelNativeBestEffort(attempt)
		}
		attempt = nil
	}
	if codexAuthSnapshotReady(snapshot) {
		safeToPublish := true
		terminal := codexAuthIssueSnapshot("login_failed", m.now().UnixMilli())
		if attempt != nil {
			if !attempt.completionObserved {
				safeToPublish = m.cancelSupersededAttemptWithTerminal(attempt, terminal)
			}
			m.removeAttemptIfCurrent(target.key(), attempt)
		}
		if safeToPublish && m.publishSnapshotForRuntime(target, runtime, snapshot) {
			if refreshed := m.refreshTargetAndPublish(ctx, target); refreshed != nil {
				snapshot = mapParam(refreshed, "auth")
			}
		} else if !safeToPublish {
			snapshot = terminal
		} else {
			snapshot = codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli())
		}
		return map[string]any{"auth": snapshot}, nil
	}
	if attempt != nil {
		pending := codexPendingAuthSnapshot(m.now().UnixMilli())
		m.publishSnapshotForRuntime(target, runtime, pending)
		return map[string]any{
			"auth":       pending,
			"attempt_id": attempt.attemptID,
			"flow":       attempt.flow,
			"expires_at": attempt.expiresAt,
		}, nil
	}

	m.publishSnapshotForRuntime(target, runtime, snapshot)
	return map[string]any{"auth": snapshot}, nil
}

func (m *runtimeAuthCoordinator) start(
	ctx context.Context,
	target runtimeProbeTarget,
	flow string,
) (map[string]any, error) {
	return m.startScoped(ctx, target, flow, nil, nil)
}

func (m *runtimeAuthCoordinator) startScoped(ctx context.Context, target runtimeProbeTarget, flow string, scope *runtimeAuthInputContext, local *runtimeAuthPrivateTarget) (map[string]any, error) {
	unlock := m.lockTarget(target.key())
	defer unlock()
	current := func() bool { return scope == nil || m.codex.connector.privateRuntimeAuthCurrent(ctx, local, *scope) }
	if !current() {
		return nil, errors.New("runtime auth target changed")
	}
	if m.targetBusy(target) {
		return nil, errors.New("runtime_busy")
	}

	if expired := m.takeExpiredAttempt(target.key()); expired != nil {
		m.retireExpiredAttempt(target, expired)
	}
	if existing := m.attempt(target.key()); existing != nil {
		if existing.input != nil {
			return nil, errors.New("runtime auth mutation is active")
		}
		if !m.codex.currentRuntime(existing.runtime) {
			if m.removeAttemptIfCurrent(target.key(), existing) {
				m.cancelNativeBestEffort(existing)
			}
		} else {
			if (scope == nil) != (existing.scope == nil) || (scope != nil && (!sameRuntimeAuthTargetScope(*scope, *existing.scope) || scope.ActorID != existing.scope.ActorID || !current())) {
				return nil, errors.New("runtime auth mutation is active")
			}
			if existing.flow != flow {
				return nil, errors.New("runtime auth login conflict: another flow is active")
			}
			return codexAuthStartResult(existing, true), nil
		}
	}
	if flow != runtimeAuthFlowDeviceCode {
		return nil, errors.New("runtime auth flow is unsupported")
	}

	runtime, snapshot, err := m.codex.readRuntimeAuthSnapshot(ctx, target)
	if err != nil {
		m.publishSnapshotForRuntime(
			target,
			runtime,
			codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli()),
		)
		return nil, errors.New("runtime auth probe failed")
	}
	if codexAuthSnapshotReady(snapshot) {
		m.publishSnapshotForRuntime(target, runtime, snapshot)
		return nil, errors.New("runtime is already authenticated")
	}

	result, err := runtime.rpc(
		ctx,
		"account/login/start",
		map[string]any{"type": "chatgptDeviceCode"},
		m.startTimeout,
	)
	if err != nil {
		// A transport error or timeout after account/login/start was dispatched
		// is ambiguous: the app-server may have created a native flow and lost
		// the response. An explicit JSON-RPC error is a complete response and does
		// not require a process fence.
		snapshot := codexAuthIssueSnapshot("login_failed", m.now().UnixMilli())
		var responseErr *codexRPCError
		if !errors.As(err, &responseErr) {
			m.publishTerminalAndFence(runtime, snapshot)
			return nil, runtimeAuthUnknown(errors.New("runtime auth login failed"))
		} else {
			m.publishSnapshotForRuntime(target, runtime, snapshot)
		}
		return nil, errors.New("runtime auth login failed")
	}
	nativeLoginID := stringParam(result, "loginId")
	verificationURL := stringParam(result, "verificationUrl")
	userCode := stringParam(result, "userCode")
	validNativeLoginID := validRuntimeAuthLoginID(nativeLoginID)
	if stringParam(result, "type") != "chatgptDeviceCode" ||
		!validNativeLoginID ||
		!validRuntimeAuthVerificationURL(verificationURL) ||
		!validRuntimeAuthUserCode(userCode) {
		if validNativeLoginID {
			if !m.cancelSupersededAttempt(&runtimeAuthAttempt{
				nativeLoginID: nativeLoginID,
				runtime:       runtime,
			}) {
				return nil, runtimeAuthUnknown(errors.New("runtime auth login returned an invalid device-code ceremony"))
			}
		} else {
			// A malformed/missing login id gives us no exact native handle. Keep
			// session-bearing generations alive but quarantine them for auth; an
			// unbound generation can be terminated immediately.
			m.codex.fenceRuntimeGeneration(runtime)
			return nil, runtimeAuthUnknown(errors.New("runtime auth login returned an invalid device-code ceremony"))
		}
		return nil, errors.New("runtime auth login returned an invalid device-code ceremony")
	}
	_, targetPresent := m.codex.connector.runtimeInventory.target(target.provider, target.identityMaterial)
	if !targetPresent {
		m.cancelSupersededAttempt(&runtimeAuthAttempt{nativeLoginID: nativeLoginID, runtime: runtime})
		return nil, errors.New("runtime auth target changed before login started")
	}

	attempt := &runtimeAuthAttempt{
		scope: scope, target: local,
		attemptID:         randomHex(16),
		flow:              flow,
		nativeLoginID:     nativeLoginID,
		verificationURL:   verificationURL,
		userCode:          userCode,
		expiresAt:         m.now().Add(m.ttl).UnixMilli(),
		runtime:           runtime,
		runtimeGeneration: runtime.generation,
	}
	if !m.codex.currentRuntime(runtime) || !current() {
		m.cancelSupersededAttempt(attempt)
		return nil, errors.New("runtime auth target changed before login started")
	}
	m.mu.Lock()
	m.attempts[target.key()] = attempt
	m.mu.Unlock()
	// The app-server can exit after answering account/login/start. Recheck the
	// exact process generation after insertion; runtimeClosed is serialized by
	// the same target lock and will clear a later exit.
	if !m.codex.currentRuntime(runtime) {
		m.removeAttemptIfCurrent(target.key(), attempt)
		m.cancelSupersededAttempt(attempt)
		return nil, errors.New("runtime auth target changed before login started")
	}
	if m.beforePendingPublication != nil {
		m.beforePendingPublication()
	}
	if !current() || !m.publishSnapshotForRuntime(target, runtime, codexPendingAuthSnapshot(m.now().UnixMilli())) {
		m.removeAttemptIfCurrent(target.key(), attempt)
		m.cancelSupersededAttempt(attempt)
		return nil, errors.New("runtime auth target changed before login started")
	}
	return codexAuthStartResult(attempt, false), nil
}

func (m *runtimeAuthCoordinator) cancel(
	ctx context.Context,
	target runtimeProbeTarget,
	attemptID string,
) (map[string]any, error) {
	unlock := m.lockTarget(target.key())
	defer unlock()

	return m.cancelLocked(ctx, target, attemptID)
}

func (m *runtimeAuthCoordinator) cancelLocked(ctx context.Context, target runtimeProbeTarget, attemptID string) (map[string]any, error) {
	attempt := m.attempt(target.key())
	if attempt == nil || attempt.attemptID != attemptID {
		return nil, errors.New("runtime auth attempt is no longer active")
	}
	if attempt.input != nil {
		return nil, errors.New("runtime auth private attempt requires authorized cancellation")
	}
	if !m.codex.currentRuntime(attempt.runtime) {
		m.removeAttemptIfCurrent(target.key(), attempt)
		m.cancelNativeBestEffort(attempt)
		return nil, errors.New("runtime auth attempt is no longer active")
	}
	result, err := attempt.runtime.rpc(
		ctx,
		"account/login/cancel",
		map[string]any{"loginId": attempt.nativeLoginID},
		m.cancelTimeout,
	)
	if err != nil {
		return m.finishUnconfirmedCancel(target, attempt), runtimeAuthUnknown(errors.New("runtime auth login cancellation was not confirmed"))
	}
	status := stringParam(result, "status")
	if status != "canceled" && status != "notFound" {
		return m.finishUnconfirmedCancel(target, attempt), runtimeAuthUnknown(errors.New("runtime auth login cancellation was not confirmed"))
	}
	if !m.removeAttemptIfCurrent(target.key(), attempt) {
		return nil, errors.New("runtime auth attempt changed during cancel")
	}
	runtime, snapshot, readErr := m.codex.readRuntimeAuthSnapshot(ctx, target)
	if readErr != nil {
		snapshot = codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli())
	}
	m.publishSnapshotForRuntime(target, runtime, snapshot)
	return map[string]any{
		"attempt_id": attemptID,
		"canceled":   status == "canceled" || status == "notFound",
		"auth":       snapshot,
	}, nil
}

func (m *runtimeAuthCoordinator) finishUnconfirmedCancel(
	target runtimeProbeTarget,
	attempt *runtimeAuthAttempt,
) map[string]any {
	snapshot := codexAuthIssueSnapshot("login_failed", m.now().UnixMilli())
	if m.removeAttemptIfCurrent(target.key(), attempt) {
		m.publishTerminalAndFence(attempt.runtime, snapshot)
	} else {
		m.codex.fenceRuntimeGeneration(attempt.runtime)
	}
	// The request did not confirm native cancellation. Whether the response was
	// lost, rejected, or malformed, quarantine a session-bound generation for
	// auth or terminate an unbound one so it cannot influence auth state or race
	// a retry through this Connector generation.
	return map[string]any{
		"attempt_id": attempt.attemptID,
		"canceled":   true,
		"auth":       snapshot,
	}
}

func (m *runtimeAuthCoordinator) handleNotification(runtime *codexRuntime, event map[string]any) {
	method := stringParam(event, "method")
	if method != "account/login/completed" && method != "account/updated" {
		return
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}
	key := target.key()
	params := mapParam(event, "params")

	m.codex.enqueueAuthNotificationIfCurrent(runtime, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		state := m.notifications[key]
		if state == nil {
			state = &codexAuthNotificationState{}
			m.notifications[key] = state
		}
		if state.runtime != runtime {
			// Replacement is excluded while this enqueue holds the implementation
			// lock, so only the newly-current generation can reset queued evidence.
			state.runtime = runtime
			state.accountUpdated = false
			state.completion = nil
		}
		switch method {
		case "account/updated":
			state.accountUpdated = true
		case "account/login/completed":
			attempt := m.attempts[key]
			loginID := stringParam(params, "loginId")
			if attempt != nil && attempt.runtime == runtime &&
				attempt.runtimeGeneration == runtime.generation &&
				loginID == attempt.nativeLoginID {
				success, valid := params["success"].(bool)
				state.completion = &codexAuthCompletion{
					loginID: loginID,
					success: success,
					valid:   valid,
				}
			}
		}
		if !state.running && (state.accountUpdated || state.completion != nil) {
			state.running = true
			go m.notificationLoop(key, state)
		}
	})
}

func (m *runtimeAuthCoordinator) notificationLoop(key string, state *codexAuthNotificationState) {
	for {
		m.mu.Lock()
		if m.notifications[key] != state ||
			(!state.accountUpdated && state.completion == nil) {
			state.running = false
			if m.notifications[key] == state {
				delete(m.notifications, key)
			}
			m.mu.Unlock()
			return
		}
		runtime := state.runtime
		accountUpdated := state.accountUpdated
		completion := state.completion
		state.accountUpdated = false
		state.completion = nil
		m.mu.Unlock()

		m.processNotificationBatch(runtime, accountUpdated, completion)
	}
}

func (m *runtimeAuthCoordinator) processNotificationBatch(
	runtime *codexRuntime,
	accountUpdated bool,
	completion *codexAuthCompletion,
) {
	target := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}
	unlock := m.lockTarget(target.key())
	defer unlock()
	if !m.codex.currentRuntime(runtime) {
		return
	}

	attempt := m.attempt(target.key())
	if attempt != nil && attempt.input != nil {
		return
	}
	if attempt != nil && attempt.expiresAt <= m.now().UnixMilli() {
		if m.removeAttemptIfCurrent(target.key(), attempt) {
			m.retireExpiredAttempt(target, attempt)
		}
		return
	}
	if attempt != nil && (attempt.runtime != runtime || attempt.runtimeGeneration != runtime.generation) {
		if m.removeAttemptIfCurrent(target.key(), attempt) {
			m.cancelSupersededAttempt(attempt)
		}
		attempt = nil
	}
	if attempt == nil {
		if !accountUpdated {
			return
		}
		readCtx, cancelRead := context.WithTimeout(context.Background(), runtimeAuthNotificationReadTimeout)
		snapshot, err := m.codex.readRuntimeAuthSnapshotFromRuntime(readCtx, runtime)
		cancelRead()
		if err != nil {
			m.publishSnapshotForRuntime(
				target,
				runtime,
				codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli()),
			)
			return
		}
		if !m.publishSnapshotForRuntime(target, runtime, snapshot) {
			return
		}
		m.refreshTargetAndPublishBounded(target)
		return
	}
	if completion != nil {
		if completion.loginID != attempt.nativeLoginID {
			return
		}
		if !completion.valid || !completion.success {
			if m.removeAttemptIfCurrent(target.key(), attempt) {
				m.publishSnapshotForRuntime(
					target,
					runtime,
					codexAuthIssueSnapshot("login_failed", m.now().UnixMilli()),
				)
			}
			return
		}
		attempt.completionObserved = true
	}

	readCtx, cancelRead := context.WithTimeout(context.Background(), runtimeAuthNotificationReadTimeout)
	snapshot, err := m.codex.readRuntimeAuthSnapshotFromRuntime(readCtx, runtime)
	cancelRead()
	if err != nil {
		m.publishSnapshotForRuntime(
			target,
			runtime,
			codexAuthIssueSnapshot("auth_probe_failed", m.now().UnixMilli()),
		)
		return
	}
	if !codexAuthSnapshotReady(snapshot) {
		if accountUpdated {
			m.publishSnapshotForRuntime(target, runtime, codexPendingAuthSnapshot(m.now().UnixMilli()))
		}
		return
	}
	safeToPublish := true
	terminal := codexAuthIssueSnapshot("login_failed", m.now().UnixMilli())
	if !attempt.completionObserved {
		// An authenticated account/read without the matching native completion
		// can be an external sign-in. Cancel the exact still-live device flow (or
		// fence its process if cancellation is ambiguous) before publishing ready.
		safeToPublish = m.cancelSupersededAttemptWithTerminal(attempt, terminal)
	}
	if m.removeAttemptIfCurrent(target.key(), attempt) {
		if safeToPublish && m.publishSnapshotForRuntime(target, runtime, snapshot) {
			m.refreshTargetAndPublishBounded(target)
		}
	}
}

func (m *runtimeAuthCoordinator) runtimeClosed(runtime *codexRuntime) {
	target := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}
	unlock := m.lockTarget(target.key())
	defer unlock()
	attempt := m.attempt(target.key())
	if attempt == nil || attempt.runtime != runtime || attempt.runtimeGeneration != runtime.generation {
		return
	}
	if m.removeAttemptIfCurrent(target.key(), attempt) {
		issue := "login_failed"
		if attempt.expiresAt <= m.now().UnixMilli() {
			issue = "login_timeout"
		}
		m.publishClosingSnapshot(
			target,
			runtime,
			codexAuthIssueSnapshot(issue, m.now().UnixMilli()),
		)
	}
}

// runtimeTransportClosed atomically publishes an active ceremony's terminal
// state and removes the exact runtime owner before the still-live app-server is
// terminated. Codex websocket listeners outlive disconnected clients, but an
// initialized JSON-RPC connection cannot be reused.
func (m *runtimeAuthCoordinator) runtimeTransportClosed(runtime *codexRuntime) {
	if runtime == nil {
		return
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}
	unlock := m.lockTarget(target.key())
	attempt := m.attempt(target.key())
	var snapshot map[string]any
	if attempt != nil && attempt.runtime == runtime &&
		attempt.runtimeGeneration == runtime.generation &&
		m.removeAttemptIfCurrent(target.key(), attempt) {
		issue := "login_failed"
		if attempt.expiresAt <= m.now().UnixMilli() {
			issue = "login_timeout"
		}
		snapshot = codexAuthIssueSnapshot(issue, m.now().UnixMilli())
	}
	published := m.codex.retireRuntimeTransport(target, runtime, snapshot)
	unlock()
	runtime.terminate()
	if published {
		m.codex.connector.publishCachedMetadata()
	}
}

func (m *runtimeAuthCoordinator) refreshTargetAndPublish(ctx context.Context, target runtimeProbeTarget) map[string]any {
	runtimes, _ := m.codex.connector.runtimeInventory.probe(
		ctx,
		target.provider,
		target.identityMaterial,
		"operator",
	)
	m.codex.connector.publishCachedMetadata()
	if len(runtimes) == 1 {
		return runtimes[0]
	}
	return nil
}

func (m *runtimeAuthCoordinator) refreshTargetAndPublishBounded(target runtimeProbeTarget) map[string]any {
	ctx, cancel := context.WithTimeout(context.Background(), runtimeAuthNotificationProbeTimeout)
	defer cancel()
	return m.refreshTargetAndPublish(ctx, target)
}

func (m *runtimeAuthCoordinator) publishSnapshotForRuntime(
	target runtimeProbeTarget,
	runtime *codexRuntime,
	snapshot map[string]any,
) bool {
	if m.codex.updateAuthSnapshotForRuntime(target, runtime, snapshot, true) {
		m.codex.connector.publishCachedMetadata()
		return true
	}
	return false
}

func (m *runtimeAuthCoordinator) publishClosingSnapshot(
	target runtimeProbeTarget,
	runtime *codexRuntime,
	snapshot map[string]any,
) bool {
	if m.codex.updateAuthSnapshotForRuntime(target, runtime, snapshot, false) {
		m.codex.connector.publishCachedMetadata()
		return true
	}
	return false
}

func (m *runtimeAuthCoordinator) cancelNativeBestEffort(attempt *runtimeAuthAttempt) {
	m.cancelNativeLoginBestEffort(attempt.runtime, attempt.nativeLoginID)
}

func (m *runtimeAuthCoordinator) retireExpiredAttempt(
	target runtimeProbeTarget,
	attempt *runtimeAuthAttempt,
) map[string]any {
	snapshot := codexAuthIssueSnapshot("login_timeout", m.now().UnixMilli())
	if attempt.input != nil {
		return snapshot
	}
	safelyCanceled := m.cancelSupersededAttemptWithTerminal(attempt, snapshot)
	// A completion/account update may already be in flight when Connector TTL
	// expires. Fence this generation even after a confirmed native cancel so late
	// ceremony evidence cannot be reclassified as an unrelated external sign-in.
	if safelyCanceled {
		m.publishTerminalAndFence(attempt.runtime, snapshot)
	}
	return snapshot
}

func (m *runtimeAuthCoordinator) cancelSupersededAttempt(attempt *runtimeAuthAttempt) bool {
	return m.cancelSupersededAttemptWithTerminal(attempt, nil)
}

func (m *runtimeAuthCoordinator) cancelSupersededAttemptWithTerminal(
	attempt *runtimeAuthAttempt,
	terminal map[string]any,
) bool {
	if attempt == nil || attempt.runtime == nil {
		return false
	}
	cancelCtx, cancel := context.WithTimeout(context.Background(), m.nativeCancelTimeout)
	result, err := attempt.runtime.rpc(
		cancelCtx,
		"account/login/cancel",
		map[string]any{"loginId": attempt.nativeLoginID},
		m.nativeCancelTimeout,
	)
	cancel()
	status := stringParam(result, "status")
	if err != nil || (status != "canceled" && status != "notFound") {
		// An ambiguous cancel cannot prove that the native device flow stopped.
		// Fence auth on this exact generation. Unbound runtimes are terminated so
		// a retry uses a fresh app-server; session-bound runtimes keep serving
		// their sessions but remain quarantined from further auth operations.
		if terminal != nil {
			m.publishTerminalAndFence(attempt.runtime, terminal)
		} else {
			m.codex.fenceRuntimeGeneration(attempt.runtime)
		}
		return false
	}
	return true
}

func (m *runtimeAuthCoordinator) publishTerminalAndFence(
	runtime *codexRuntime,
	snapshot map[string]any,
) {
	if m.codex.fenceRuntimeGenerationWithSnapshot(runtime, snapshot) {
		m.codex.connector.publishCachedMetadata()
	}
}

func (m *runtimeAuthCoordinator) cancelNativeLoginBestEffort(runtime *codexRuntime, nativeLoginID string) {
	cancelCtx, cancel := context.WithTimeout(context.Background(), m.nativeCancelTimeout)
	defer cancel()
	_, _ = runtime.rpc(
		cancelCtx,
		"account/login/cancel",
		map[string]any{"loginId": nativeLoginID},
		m.nativeCancelTimeout,
	)
}

// Idle reclamation must not wait behind an interactive authentication call.
// A contended target keeps the VM awake and is checked on the next sweep.
func (m *runtimeAuthCoordinator) tryLockTarget(key string) (func(), bool) {
	m.mu.Lock()
	lock := m.locks[key]
	if lock == nil {
		lock = &runtimeAuthTargetLock{}
		m.locks[key] = lock
	}
	lock.users++
	m.mu.Unlock()
	if !lock.mutex.TryLock() {
		m.mu.Lock()
		lock.users--
		if lock.users == 0 && lock.nativeCalls == 0 {
			delete(m.locks, key)
		}
		m.mu.Unlock()
		return nil, false
	}
	return func() {
		lock.mutex.Unlock()
		m.mu.Lock()
		lock.users--
		if lock.users == 0 && lock.nativeCalls == 0 {
			delete(m.locks, key)
		}
		m.mu.Unlock()
	}, true
}

func (m *runtimeAuthCoordinator) lockTarget(key string) func() {
	m.mu.Lock()
	lock := m.locks[key]
	if lock == nil {
		lock = &runtimeAuthTargetLock{}
		m.locks[key] = lock
	}
	lock.users++
	m.mu.Unlock()
	lock.mutex.Lock()
	return func() {
		lock.mutex.Unlock()
		m.mu.Lock()
		lock.users--
		if lock.users == 0 && lock.nativeCalls == 0 {
			delete(m.locks, key)
		}
		m.mu.Unlock()
	}
}

// Native Send/recovery admission and auth commit share this target section.
// Calls do not hold the section while waiting on native I/O: the count keeps
// auth busy even if a fast terminal event removes its durable execution before
// the original native RPC returns. RuntimeAuthMutation.tla models this seam.
func (m *runtimeAuthCoordinator) enterNativeCall(target runtimeProbeTarget) func() {
	unlock := m.lockTarget(target.key())
	m.mu.Lock()
	lock := m.locks[target.key()]
	lock.nativeCalls++
	m.mu.Unlock()
	unlock()
	return func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		lock.nativeCalls--
		if lock.users == 0 && lock.nativeCalls == 0 {
			delete(m.locks, target.key())
		}
	}
}

func (c *connector) enterRuntimeAuthNativeCall(provider, command string) func() {
	if owner := c.runtimeAuthCoordinator(); owner != nil {
		return owner.enterNativeCall(runtimeProbeTarget{provider: provider, identityMaterial: command})
	}
	// Scope-limited connectors and non-native test implementations expose no
	// auth owner or private-input capability.
	return func() {}
}

// Caller holds the target section, which excludes new native call admission.
// The existing execution owner supplies its indexed count, including durable
// recovery obligations. This path performs no session scan or child RPC.
func (m *runtimeAuthCoordinator) targetBusy(target runtimeProbeTarget) bool {
	m.mu.Lock()
	lock := m.locks[target.key()]
	busy := lock != nil && lock.nativeCalls > 0
	m.mu.Unlock()
	if !busy && m.codex != nil && m.codex.connector.externalRuntimeState != nil {
		busy = m.codex.connector.externalRuntimeState.targetHasActiveExecution(target)
	}
	return busy
}

func (m *runtimeAuthCoordinator) attempt(key string) *runtimeAuthAttempt {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.attempts[key]
}

func (m *runtimeAuthCoordinator) takeExpiredAttempt(key string) *runtimeAuthAttempt {
	m.mu.Lock()
	defer m.mu.Unlock()
	attempt := m.attempts[key]
	if attempt == nil || attempt.expiresAt > m.now().UnixMilli() {
		return nil
	}
	delete(m.attempts, key)
	attempt.destroyInput()
	return attempt
}

func (m *runtimeAuthCoordinator) removeAttemptIfCurrent(key string, attempt *runtimeAuthAttempt) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.attempts[key] != attempt {
		return false
	}
	delete(m.attempts, key)
	attempt.destroyInput()
	return true
}

func (m *runtimeAuthCoordinator) hasPendingAttemptForRuntime(runtime *codexRuntime) bool {
	if runtime == nil {
		return false
	}
	now := m.now().UnixMilli()
	key := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}.key()
	m.mu.Lock()
	defer m.mu.Unlock()
	attempt := m.attempts[key]
	return attempt != nil && attempt.runtime == runtime &&
		attempt.runtimeGeneration == runtime.generation && attempt.expiresAt > now
}

func codexAuthStartResult(attempt *runtimeAuthAttempt, reused bool) map[string]any {
	return map[string]any{
		"attempt_id":       attempt.attemptID,
		"flow":             attempt.flow,
		"verification_url": attempt.verificationURL,
		"user_code":        attempt.userCode,
		"expires_at":       attempt.expiresAt,
		"reused":           reused,
		"auth":             codexPendingAuthSnapshot(time.Now().UnixMilli()),
	}
}

func validRuntimeAuthLoginID(value string) bool {
	value = strings.TrimSpace(value)
	return value != "" && len(value) <= 256
}

func validRuntimeAuthVerificationURL(value string) bool {
	return value == "https://auth.openai.com/codex/device"
}

func validRuntimeAuthUserCode(value string) bool {
	if value == "" || len(value) > 128 || !utf8.ValidString(value) || strings.TrimSpace(value) != value {
		return false
	}
	for _, char := range []byte(value) {
		if char <= 0x20 || char == 0x7f {
			return false
		}
	}
	return true
}

func codexAuthSnapshotFromAccount(result map[string]any, observedAt int64) (map[string]any, error) {
	requiresOpenAIAuth, ok := result["requiresOpenaiAuth"].(bool)
	if !ok {
		return nil, errors.New("account/read omitted requiresOpenaiAuth")
	}
	base := map[string]any{
		"schema_version":       1,
		"requires_openai_auth": requiresOpenAIAuth,
		"observed_at":          observedAt,
	}
	accountValue, hasAccount := result["account"]
	if !hasAccount || accountValue == nil {
		if requiresOpenAIAuth {
			base["status"] = "unauthenticated"
		} else {
			base["status"] = "not_required"
		}
		return base, nil
	}
	account, ok := accountValue.(map[string]any)
	if !ok || len(account) == 0 {
		return nil, errors.New("account/read returned a malformed account")
	}
	base["status"] = "authenticated"
	switch stringParam(account, "type") {
	case "chatgpt":
		base["mode"] = "chatgpt"
	case "apiKey":
		base["mode"] = "api_key"
		base["status"] = "configured"
	case "amazonBedrock":
		base["mode"] = "amazon_bedrock"
	default:
		base["mode"] = "other"
	}
	return base, nil
}

func codexPendingAuthSnapshot(observedAt int64) map[string]any {
	return map[string]any{
		"schema_version":       1,
		"status":               "pending",
		"mode":                 "chatgpt",
		"requires_openai_auth": true,
		"observed_at":          observedAt,
	}
}

func codexAuthIssueSnapshot(issue string, observedAt int64) map[string]any {
	return map[string]any{
		"schema_version":       1,
		"status":               "error",
		"requires_openai_auth": true,
		"observed_at":          observedAt,
		"issue":                issue,
	}
}

func codexAuthSnapshotReady(snapshot map[string]any) bool {
	status := stringParam(snapshot, "status")
	return status == "authenticated" || status == "not_required"
}

func cloneAuthSnapshot(snapshot map[string]any) map[string]any {
	cloned := make(map[string]any, len(snapshot))
	for key, value := range snapshot {
		cloned[key] = value
	}
	return cloned
}

func (i *codexRuntimeImplementation) ensureTargetRuntime(
	ctx context.Context,
	target runtimeProbeTarget,
) (*codexRuntime, error) {
	if target.provider != "codex" || target.identityMaterial == "" {
		return nil, errors.New("invalid codex runtime target")
	}
	bridgeURL, err := i.connector.ensureRuntimeBridge()
	if err != nil {
		return nil, err
	}
	i.mu.Lock()
	if i.closed {
		i.mu.Unlock()
		return nil, errCodexAppServerUnavailable
	}
	existing := i.runtimes[target.identityMaterial]
	if existing != nil && existing.isRunning() {
		if i.authQuarantined[existing.generation] {
			i.mu.Unlock()
			return nil, errCodexAuthGenerationQuarantined
		}
		i.mu.Unlock()
		return existing, nil
	}
	runtime, err := i.startRuntime(externalRuntimeInput{command: target.identityMaterial}, bridgeURL)
	if err != nil {
		i.mu.Unlock()
		return nil, err
	}
	i.runtimes[target.identityMaterial] = runtime
	runtime.start()
	err = runtime.connect(ctx)
	i.mu.Unlock()
	if err != nil {
		// Auth callers already hold the per-target lock. Waiting for done here
		// would deadlock with finish -> runtimeClosed, which takes that same
		// lock before closing done. Fence this exact unusable generation and let
		// its ordinary process callback recover any bound sessions asynchronously.
		i.retireUnusableRuntimeGeneration(runtime)
		return nil, err
	}
	return runtime, nil
}

func (i *codexRuntimeImplementation) currentRuntime(runtime *codexRuntime) bool {
	if runtime == nil || !runtime.isRunning() {
		return false
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.runtimes[runtime.command] == runtime && !i.authQuarantined[runtime.generation]
}

func (i *codexRuntimeImplementation) enqueueAuthNotificationIfCurrent(
	runtime *codexRuntime,
	enqueue func(),
) bool {
	if runtime == nil || !runtime.isRunning() {
		return false
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.runtimes[runtime.command] != runtime || i.authQuarantined[runtime.generation] {
		return false
	}
	// Replacement/quarantine and queue mutation share the implementation lock,
	// so a late G1 handler cannot clear or replace already-enqueued G2 evidence.
	enqueue()
	return true
}

// updateAuthSnapshotForRuntime is modeled in tla/connector/RuntimeAuth.tla as
// the atomic snapshot/epoch publication boundary and in
// tla/connector/RuntimeAuthReadiness.tla as the generation-owned readiness proof.
func (i *codexRuntimeImplementation) updateAuthSnapshotForRuntime(
	target runtimeProbeTarget,
	runtime *codexRuntime,
	snapshot map[string]any,
	requireRunning bool,
) bool {
	if runtime == nil || runtime.command != target.identityMaterial ||
		runtime.generation == "" {
		return false
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	current := i.runtimes[target.identityMaterial]
	if current != runtime || current.generation != runtime.generation ||
		i.authQuarantined[runtime.generation] ||
		(requireRunning && !current.isRunning()) {
		return false
	}
	// Keep the generation check and inventory mutation under the same lock.
	// A replacement cannot become current between them and accept stale G1
	// auth evidence into G2's public observation.
	authReady := codexAuthSnapshotReady(snapshot)
	preserveFullReadiness := authReady && runtime.fullReadinessProven
	if !i.connector.runtimeInventory.updateAuthSnapshot(target, snapshot, preserveFullReadiness) {
		return false
	}
	if !authReady {
		runtime.fullReadinessProven = false
	}
	runtime.authEpoch++
	return true
}

// commitRuntimeProbe's generation/epoch fence is modeled in
// tla/connector/RuntimeAuth.tla and tla/connector/RuntimeAuthReadiness.tla.
func (i *codexRuntimeImplementation) commitRuntimeProbe(
	target runtimeProbeTarget,
	generation string,
	authEpoch uint64,
	observation map[string]any,
	commit func(),
) bool {
	if target.provider != "codex" {
		owner := i.connector.runtimeAuthCoordinator()
		unlock := owner.lockTarget(target.key())
		defer unlock()
		i.connector.connectionMu.Lock()
		defer i.connector.connectionMu.Unlock()
		i.connector.sendMu.Lock()
		defer i.connector.sendMu.Unlock()
		owner.applyVerificationObservationLocked(target, observation)
		commit()
		return true
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	current := i.runtimes[target.identityMaterial]
	if generation == "" {
		// A version-only failure has no process generation. It is safe to commit
		// only when there is no live process whose newer observation it could
		// replace.
		if current != nil && current.isRunning() {
			return false
		}
	} else if current == nil || current.generation != generation || !current.isRunning() ||
		i.authQuarantined[generation] || current.authEpoch != authEpoch {
		return false
	}
	commit()
	if generation != "" {
		current.authEpoch++
		current.fullReadinessProven = i.connector.runtimeInventory.fullReadinessInputsReady(target)
	}
	return true
}

// fenceRuntimeGeneration is modeled in tla/connector/RuntimeAuth.tla as the
// terminate-or-quarantine generation fence.
func (i *codexRuntimeImplementation) fenceRuntimeGeneration(runtime *codexRuntime) {
	i.fenceRuntimeGenerationWithSnapshot(runtime, nil)
}

func (i *codexRuntimeImplementation) fenceRuntimeGenerationWithSnapshot(
	runtime *codexRuntime,
	snapshot map[string]any,
) bool {
	if runtime == nil {
		return false
	}
	i.mu.Lock()
	current := i.runtimes[runtime.command]
	published := false
	if snapshot != nil && current == runtime && current.generation == runtime.generation {
		target := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}
		if i.connector.runtimeInventory.updateAuthSnapshot(target, snapshot, false) {
			runtime.authEpoch++
			if !codexAuthSnapshotReady(snapshot) {
				runtime.fullReadinessProven = false
			}
			published = true
		}
	}
	bound := false
	for _, session := range i.sessions {
		if session == nil {
			continue
		}
		session.mu.Lock()
		bound = session.runtime == runtime
		session.mu.Unlock()
		if bound {
			break
		}
	}
	if bound {
		i.authQuarantined[runtime.generation] = true
		i.mu.Unlock()
		return published
	}
	if current == runtime {
		delete(i.runtimes, runtime.command)
	}
	delete(i.authQuarantined, runtime.generation)
	i.mu.Unlock()
	// Do not wait here: callers hold the per-target auth lock, while the process
	// close callback takes that same lock to retire attempts. Removing the map
	// entry first is the admission fence; process-group termination then makes
	// the ambiguous native operation short-lived without a lock cycle.
	runtime.terminate()
	return published
}

func (i *codexRuntimeImplementation) retireRuntimeTransport(
	target runtimeProbeTarget,
	runtime *codexRuntime,
	snapshot map[string]any,
) bool {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.runtimes[target.identityMaterial] != runtime ||
		runtime.command != target.identityMaterial {
		delete(i.authQuarantined, runtime.generation)
		return false
	}
	published := false
	if snapshot != nil && !i.authQuarantined[runtime.generation] &&
		i.connector.runtimeInventory.updateAuthSnapshot(target, snapshot, false) {
		runtime.authEpoch++
		if !codexAuthSnapshotReady(snapshot) {
			runtime.fullReadinessProven = false
		}
		published = true
	}
	delete(i.runtimes, target.identityMaterial)
	delete(i.authQuarantined, runtime.generation)
	return published
}

// retireUnusableRuntimeGeneration is modeled in tla/connector/RuntimeAuth.tla
// as RetireUnusableRuntime. It is the nonblocking admission fence for a Codex
// connection that never became usable or whose initialize outcome is
// ambiguous. It removes only the exact current generation, publishes a safe
// auth error while that generation still owns the cache, and leaves session
// references intact so the normal process-exit callback performs recovery.
func (i *codexRuntimeImplementation) retireUnusableRuntimeGeneration(runtime *codexRuntime) {
	if runtime == nil {
		return
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: runtime.command}
	published := i.retireRuntimeTransport(
		target,
		runtime,
		codexAuthIssueSnapshot("auth_probe_failed", time.Now().UnixMilli()),
	)
	runtime.terminate()
	if published {
		i.connector.publishCachedMetadata()
	}
}

func (i *codexRuntimeImplementation) readRuntimeAuthSnapshot(
	ctx context.Context,
	target runtimeProbeTarget,
) (*codexRuntime, map[string]any, error) {
	runtime, err := i.ensureTargetRuntime(ctx, target)
	if err != nil {
		return nil, nil, err
	}
	snapshot, err := i.readRuntimeAuthSnapshotFromRuntime(ctx, runtime)
	return runtime, snapshot, err
}

func (i *codexRuntimeImplementation) readRuntimeAuthSnapshotFromRuntime(
	ctx context.Context,
	runtime *codexRuntime,
) (map[string]any, error) {
	if !runtime.isRunning() {
		return nil, errCodexAppServerUnavailable
	}
	if err := runtime.ensureInitialized(ctx); err != nil {
		return nil, err
	}
	account, err := runtime.rpc(
		ctx,
		"account/read",
		map[string]any{"refreshToken": false},
		10*time.Second,
	)
	if err != nil {
		return nil, err
	}
	return codexAuthSnapshotFromAccount(account, time.Now().UnixMilli())
}

func (i *codexRuntimeImplementation) probeRuntimeTarget(target runtimeProbeTarget) map[string]any {
	if target.provider != "codex" {
		return probeAgentRuntimeTarget(target)
	}
	checkedAt := time.Now()
	config := detectCodexExecutionConfig()
	version, versionDetected, versionErr := codexVersion(target.identityMaterial)
	auth := codexAuthIssueSnapshot("auth_probe_failed", checkedAt.UnixMilli())
	authReady := false
	nativeServerStartable := false
	appServerStartable := false
	probeErr := ""
	var observedRuntime *codexRuntime
	var observedAuthEpoch uint64

	if versionDetected {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		runtime, err := i.ensureTargetRuntime(ctx, target)
		if err != nil {
			probeErr = "app-server start failed"
		} else {
			observedRuntime = runtime
			i.mu.Lock()
			if i.runtimes[target.identityMaterial] == runtime &&
				!i.authQuarantined[runtime.generation] {
				observedAuthEpoch = runtime.authEpoch
			}
			i.mu.Unlock()
			if err := runtime.ensureInitialized(ctx); err != nil {
				probeErr = "app-server protocol initialization failed"
			} else {
				nativeServerStartable = true
				account, accountErr := runtime.rpc(
					ctx,
					"account/read",
					map[string]any{"refreshToken": false},
					10*time.Second,
				)
				if accountErr != nil {
					probeErr = "account/read failed"
				} else if snapshot, snapshotErr := codexAuthSnapshotFromAccount(account, time.Now().UnixMilli()); snapshotErr != nil {
					probeErr = "account/read returned an invalid snapshot"
				} else {
					auth = snapshot
					// account/read remains unauthenticated while a device-code
					// ceremony is active. Preserve the exact attempt's pending
					// projection so an ordinary full probe cannot erase it.
					if i.auth.hasPendingAttemptForRuntime(runtime) {
						auth = codexPendingAuthSnapshot(time.Now().UnixMilli())
					}
					authReady = codexAuthSnapshotReady(auth)
					appServerStartable = true
					if authReady {
						if modelErr := runtime.codexModelReady(ctx, config["model"]); modelErr != nil {
							probeErr = modelErr.Error()
							appServerStartable = false
						}
					}
				}
			}
		}
		cancel()
	}

	ready := versionDetected && authReady && nativeServerStartable && appServerStartable && probeErr == ""
	readiness := map[string]any{
		"version":                 defaultString(version, "unknown"),
		"version_detected":        versionDetected,
		"app_server_startable":    appServerStartable,
		"native_server_startable": nativeServerStartable,
		"auth_ready":              authReady,
		"auth":                    auth,
		"ready":                   ready,
		"readiness_checked_at":    checkedAt.UnixMilli(),
		"readiness_valid_until":   checkedAt.Add(runtimeReadinessValidity).UnixMilli(),
		"last_error":              codexReadinessError(versionErr, probeErr),
	}
	issue, message := codexAuthReadinessDetail(versionErr, probeErr, auth)
	putNonEmpty(readiness, "readiness_issue", issue)
	putNonEmpty(readiness, "readiness_message", message)
	putNonEmpty(readiness, "model", config["model"])
	putNonEmpty(readiness, "model_provider", config["model_provider"])
	putNonEmpty(readiness, "reasoning_effort", config["reasoning_effort"])
	entry := codexRuntimeEntry(target.identityMaterial, readiness)
	if observedRuntime != nil {
		entry[runtimeProbeGenerationEvidence] = observedRuntime.generation
		entry[runtimeProbeAuthEpochEvidence] = observedAuthEpoch
	}
	i.mu.Lock()
	currentRuntime := i.runtimes[target.identityMaterial]
	generationlessBlocked := observedRuntime == nil && currentRuntime != nil && currentRuntime.isRunning()
	i.mu.Unlock()
	if generationlessBlocked {
		// The commit guard deliberately rejects generationless evidence while a
		// live runtime owns newer state. Return that cached state instead of
		// retrying forever when --version or pre-runtime setup keeps failing.
		entry[runtimeProbeNoRetryEvidence] = true
	}
	return entry
}

func (r *codexRuntime) codexModelReady(ctx context.Context, configuredModel string) error {
	models, err := r.rpc(ctx, "model/list", map[string]any{
		"includeHidden": true,
		"limit":         1000,
	}, 10*time.Second)
	if err != nil {
		return errors.New("model catalog probe failed")
	}
	configuredModel = strings.TrimSpace(configuredModel)
	if configuredModel == "" {
		return nil
	}
	items, _ := models["data"].([]any)
	for _, item := range items {
		model, _ := item.(map[string]any)
		if stringParam(model, "model") == configuredModel || stringParam(model, "id") == configuredModel {
			return nil
		}
	}
	return fmt.Errorf("configured model %q is not available to this Codex client", configuredModel)
}

func codexAuthReadinessDetail(versionErr, probeErr string, auth map[string]any) (string, string) {
	switch {
	case strings.TrimSpace(versionErr) != "":
		return "runtime_probe_failed", "The Codex version probe failed."
	case stringParam(auth, "status") == "unauthenticated":
		return "authentication_required", "Codex reports no authenticated account."
	case strings.Contains(probeErr, "configured model"):
		return "model_unavailable", "The configured Codex model is unavailable."
	case strings.TrimSpace(probeErr) != "":
		return "native_server_unavailable", "The Codex native server could not complete its readiness handshake."
	default:
		return "", ""
	}
}
