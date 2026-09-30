package main

import (
	"context"
	"time"
)

type runtimeAuthVerificationObservation struct {
	provider         string
	backend          string
	nativeGeneration string
	authEpoch        string
	status           string
	model            string
	observedAt       int64
}

// RuntimeAuthVerification.tla: provider I/O runs outside the existing target
// section. Cancellation and carrier replacement fence publication, not I/O.
// Once published, accepted evidence is target-scoped within this process and
// survives a control-carrier reconnect until its configuration owner changes.
func (m *runtimeAuthCoordinator) verifyPrivateTarget(ctx context.Context, target runtimeProbeTarget, binding runtimeAuthInputContext, local *runtimeAuthPrivateTarget, current func() bool, verify func(context.Context, string) runtimeAuthVerificationOutcome) runtimeAuthVerificationOutcome {
	return m.verifyPrivateTargetWithin(ctx, target, binding, local, current, 30*time.Second, verify)
}

func (m *runtimeAuthCoordinator) verifyPrivateTargetWithin(ctx context.Context, target runtimeProbeTarget, binding runtimeAuthInputContext, local *runtimeAuthPrivateTarget, current func() bool, timeout time.Duration, verify func(context.Context, string) runtimeAuthVerificationOutcome) runtimeAuthVerificationOutcome {
	rejected := runtimeAuthVerificationOutcome{Status: "error", Issue: "target_changed"}
	if ctx.Err() != nil || current == nil || !current() {
		return rejected
	}
	attempt, err := m.beginPrivateInput(target, binding)
	if err != nil {
		return runtimeAuthVerificationOutcome{Status: "error", Issue: "runtime_busy"}
	}
	operation, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	unlock := m.lockTarget(target.key())
	if m.attempt(target.key()) != attempt || attempt.input.phase != "awaiting_user" || !current() {
		unlock()
		return rejected
	}
	if m.privateVerification(target) != nil {
		m.invalidatePrivateVerification(target)
	}
	input := attempt.input
	attempt.target, input.verifyCancel = local, cancel
	input.outcome = runtimeAuthSaveOutcome{SaveResult: "not_requested"}
	// Verification reads the selected profile and performs one isolated provider
	// request. It does not share the mutation busy gate: after a Connector process
	// restart, durable Session recovery can already own the target and must be
	// able to regain this volatile proof. The attempt owner still excludes every
	// credential mutation and a second verification.
	input.phase = "verifying"
	unlock()

	inventory := m.codex.connector.runtimeInventory
	inventory.mu.Lock()
	observed := cloneRuntimeObservation(inventory.runtimes[target.key()])
	inventory.mu.Unlock()
	// Reuse the bounded native observation. Verification itself runs only the
	// isolated SDK adapter: starting a user's CLI here could load auth resolvers
	// or extensions before the adapter rejects executable credential material.
	outcome := runtimeAuthVerificationOutcome{Status: "error", Issue: "native_probe_failed"}
	model := stringParam(observed, "model")
	if observed["native_server_startable"] == true && int64Param(observed, "readiness_valid_until", 0) > m.now().UnixMilli() && operation.Err() == nil {
		if stringParam(mapParam(observed, "auth"), "backend") != binding.Backend || model == "" {
			outcome = runtimeAuthVerificationOutcome{Status: "error", Issue: "verification_model_unavailable"}
		} else {
			outcome = verify(operation, model)
		}
	}
	if operation.Err() != nil && ctx.Err() == nil {
		outcome = runtimeAuthVerificationOutcome{Status: "error", Issue: "verification_timeout"}
	}
	unlock = m.lockTarget(target.key())
	if m.attempt(target.key()) != attempt || input.phase != "verifying" || !current() || ctx.Err() != nil {
		if input.phase == "verifying" {
			input.phase, input.outcome.Issue = "failed", "target_changed"
		}
		unlock()
		return rejected
	}
	published := m.codex.connector.commitPrivateRuntimeAuth(ctx, local, input.context, func() runtimeAuthSaveOutcome {
		m.setPrivateVerification(target, runtimeAuthVerificationObservation{
			provider:         input.context.Provider,
			backend:          input.context.Backend,
			nativeGeneration: input.context.NativeGeneration,
			authEpoch:        input.context.AuthEpoch,
			status:           outcome.Status,
			model:            model,
			observedAt:       m.now().UnixMilli(),
		})
		input.phase, input.outcome.Issue = "failed", outcome.Issue
		if outcome.Status == "authenticated" {
			input.phase = "completed"
		}
		inventory.mu.Lock()
		if runtime := inventory.runtimes[target.key()]; runtime != nil {
			m.applyVerificationObservationLocked(target, runtime)
		}
		inventory.mu.Unlock()
		return runtimeAuthSaveOutcome{SaveResult: "not_requested"}
	})
	unlock()
	if published.Issue != "" {
		return rejected
	}
	// Verification changes dispatch admission immediately. Publish the cached,
	// credential-free observation once the target/transport critical section is
	// released so the Server does not wait for a later inventory heartbeat.
	m.codex.connector.publishCachedMetadata()
	return outcome
}

// A native probe reuses the current target-scoped observation. The explicit
// attempt bounds provider I/O and temporary input state; its expiry does not
// invent a provider revocation. Credential or native-owner replacement removes
// the observation, and reads never pay again.
// Caller holds the target section and transport sendMu before inventory.mu.
func (m *runtimeAuthCoordinator) applyVerificationObservationLocked(target runtimeProbeTarget, observed map[string]any) {
	proof := m.privateVerification(target)
	if proof == nil {
		return
	}
	if !m.privateVerificationOwnerCurrent(target) {
		m.clearPrivateVerification(target)
		return
	}
	configuredBackend := stringParam(mapParam(observed, "auth"), "backend")
	if configuredBackend != proof.backend || stringParam(observed, "model") != proof.model {
		m.clearPrivateVerification(target)
		return
	}
	observed["auth"] = map[string]any{"schema_version": 1, "status": proof.status, "requires_openai_auth": false, "observed_at": proof.observedAt, "backend": proof.backend}
	observed["auth_ready"] = proof.status == "authenticated"
	nativeReady := observed["version_detected"] == true && observed["native_server_startable"] == true && observed["app_server_startable"] == true
	issue := stringParam(observed, "readiness_issue")
	ready := observed["auth_ready"] == true && nativeReady && (issue == "" || issue == "verification_required" || issue == "authentication_required")
	observed["ready"] = ready
	observed["status"] = map[bool]string{true: "available", false: "unavailable"}[ready]
	if ready {
		delete(observed, "readiness_issue")
		delete(observed, "readiness_message")
		delete(observed, "last_error")
	}
}

func (m *runtimeAuthCoordinator) privateVerificationOwnerCurrent(target runtimeProbeTarget) bool {
	proof := m.privateVerification(target)
	if proof == nil || proof.status == "" {
		return false
	}
	switch proof.provider {
	case "pi":
		// Pi has no independently replaceable native owner. Credential mutation
		// clears this process-local target proof, and process restart destroys it.
		return true
	case "claude":
		if m.codex == nil || m.codex.connector == nil {
			return false
		}
		implementation, ok := m.codex.connector.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
		if !ok || implementation == nil {
			return false
		}
		generation, epoch := implementation.authFence()
		return proof.nativeGeneration == generation && proof.authEpoch == epoch
	default:
		return false
	}
}

func (m *runtimeAuthCoordinator) acceptedPrivateVerificationCurrent(target runtimeProbeTarget) bool {
	proof := m.privateVerification(target)
	return proof != nil && m.privateVerificationOwnerCurrent(target) && proof.status == "authenticated"
}

func (m *runtimeAuthCoordinator) privateVerification(target runtimeProbeTarget) *runtimeAuthVerificationObservation {
	m.mu.Lock()
	defer m.mu.Unlock()
	proof, ok := m.verifications[target.key()]
	if !ok {
		return nil
	}
	return &proof
}

func (m *runtimeAuthCoordinator) setPrivateVerification(target runtimeProbeTarget, proof runtimeAuthVerificationObservation) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.verifications[target.key()] = proof
}

func (m *runtimeAuthCoordinator) clearPrivateVerification(target runtimeProbeTarget) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.verifications, target.key())
}

// Caller holds the target section so an old operation cannot invalidate a
// newer target observation.
func (m *runtimeAuthCoordinator) invalidatePrivateVerification(target runtimeProbeTarget) {
	if m.privateVerification(target) == nil {
		return
	}
	m.clearPrivateVerification(target)
	m.codex.connector.runtimeInventory.updateAuthSnapshot(target, map[string]any{
		"schema_version": 1, "status": "unknown", "requires_openai_auth": false, "observed_at": m.now().UnixMilli(),
	}, false)
}
