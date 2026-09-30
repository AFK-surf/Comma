package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestRuntimeAuthVerificationOwnership(t *testing.T) {
	for _, scenario := range []string{"verified", "canceled", "disconnected", "concurrent_native_call", "wrong_backend", "credential_changed", "permission_denied", "timeout", "expired", "changed_model", "claude_owner_replaced", "reconnected_after_verify"} {
		t.Run(scenario, func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			defer c.externalRuntimeState.close()
			deactivate := activateRuntimeTransportForTest(c, func(message) error { return nil })
			defer deactivate()
			carrier := c.getActiveTransport()
			c.runtimeInventory = newRuntimeInventory()
			implementation := newCodexRuntimeImplementation(c)
			claude := newClaudeRuntimeImplementation(c)
			c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation, "claude": claude}
			c.runtimeInventory.commitGuard = implementation.commitRuntimeProbe
			c.cfg.runtimeAgent = true
			c.cfg.computeRuntimeKind = "external_worker"
			provider, backend := "pi", "openrouter"
			if scenario == "claude_owner_replaced" {
				provider, backend = "claude", "anthropic"
			}
			c.cfg.computeRuntimeProvider = provider
			m := implementation.auth
			if scenario == "expired" {
				m.ttl = 150 * time.Millisecond
			}
			target := runtimeProbeTarget{provider: provider, identityMaterial: "test-" + provider}
			binding := runtimeAuthInputContext{ActorID: "admin", TenantID: "tenant", ProjectID: "project", TargetKind: "compute_workload", WorkloadID: "workload", Provider: provider, Backend: backend, Method: "verify", Form: "api_key", SchemaVersion: 1, ConnectionEpoch: "epoch"}
			if provider == "claude" {
				binding.NativeGeneration, binding.AuthEpoch = claude.authFence()
			}
			local := &runtimeAuthPrivateTarget{carrier: carrier}
			current := func() bool { return c.getActiveTransport() == carrier }
			var connected *connectionSession
			if scenario == "reconnected_after_verify" {
				connected = c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, nil)
				defer connected.close(nil)
				c.setIdentity(connected, "run-1", "device", "connector", "admin", 1)
				binding.TargetKind, binding.DeviceID, binding.RuntimeInstanceID, binding.Generation = "connected_runtime", "device", "run-1", "1"
				local.connection = connected
				current = func() bool { return c.privateRuntimeAuthCurrent(context.Background(), local, binding) }
			}
			selectedModel := "openai/gpt-4.1-nano"
			c.runtimeInventory.run = func(runtimeProbeTarget) map[string]any {
				observedBackend := backend
				if scenario == "wrong_backend" {
					observedBackend = "other"
				}
				return map[string]any{"kind": "external", "provider": "pi", "identity_material": target.identityMaterial,
					"model": selectedModel, "version_detected": true, "native_server_startable": true, "app_server_startable": true, "ready": false,
					"readiness_issue": "verification_required", "readiness_valid_until": time.Now().Add(time.Hour).UnixMilli(),
					"auth": map[string]any{"schema_version": 1, "status": "configured", "requires_openai_auth": false, "observed_at": time.Now().UnixMilli(), "backend": observedBackend}}
			}
			if _, err := c.runtimeInventory.probeOne(context.Background(), target, "connect"); err != nil {
				t.Fatal(err)
			}
			if scenario == "concurrent_native_call" {
				leave := m.enterNativeCall(target)
				defer leave()
			}
			var calls atomic.Int32
			verify := func(ctx context.Context, model string) runtimeAuthVerificationOutcome {
				calls.Add(1)
				if model != "openai/gpt-4.1-nano" {
					t.Fatal("verification did not use the target-selected model")
				}
				if scenario == "canceled" {
					attempt := m.attempt(target.key())
					m.cancelPrivateInput(target, attempt.attemptID, func() bool { return true })
				}
				if scenario == "disconnected" {
					deactivate()
				}
				if scenario == "permission_denied" {
					return runtimeAuthVerificationOutcome{Status: "error", Issue: "permission_denied"}
				}
				if scenario == "timeout" {
					<-ctx.Done()
				}
				return runtimeAuthVerificationOutcome{Status: "authenticated"}
			}
			verifyTimeout := 30 * time.Second
			if scenario == "timeout" {
				verifyTimeout = 10 * time.Millisecond
			}
			result := m.verifyPrivateTargetWithin(context.Background(), target, binding, local, current, verifyTimeout, verify)
			wantCalls := int32(1)
			if scenario == "wrong_backend" {
				wantCalls = 0
			}
			if calls.Load() != wantCalls {
				t.Fatalf("provider requests = %d", calls.Load())
			}
			wantVerified := scenario == "verified" || scenario == "concurrent_native_call" || scenario == "credential_changed" || scenario == "expired" || scenario == "changed_model" || scenario == "claude_owner_replaced" || scenario == "reconnected_after_verify"
			if (result.Status == "authenticated") != wantVerified {
				t.Fatalf("verification = %+v", result)
			}
			if scenario == "timeout" && result.Issue != "verification_timeout" {
				t.Fatalf("verification timeout = %+v", result)
			}
			if scenario == "changed_model" {
				selectedModel = "different-model"
			}
			if scenario == "claude_owner_replaced" {
				outcome := claude.commitAuthSettings(context.Background(), binding.NativeGeneration, binding.AuthEpoch, func() runtimeAuthSaveOutcome {
					return runtimeAuthSaveOutcome{SaveResult: "committed"}
				})
				if outcome.SaveResult != "committed" {
					t.Fatalf("replace Claude auth owner: %+v", outcome)
				}
			}
			if scenario == "reconnected_after_verify" {
				deactivate()
				connected.close(nil)
				replacement := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, nil)
				defer replacement.close(nil)
				c.setIdentity(replacement, "run-2", "device", "connector", "admin", 2)
				replacementOff := activateRuntimeTransportForTest(c, func(message) error { return nil })
				defer replacementOff()
				observed, err := c.runtimeInventory.probeOne(context.Background(), target, "reconnect")
				if err != nil || observed["ready"] != true {
					t.Fatalf("fresh reconnect probe lost stable target proof: runtime=%#v err=%v", observed, err)
				}
				status := m.status(context.Background(), target, "admin")
				if status["dispatch_ready"] != true || stringParam(mapParam(status, "auth"), "status") != "authenticated" {
					t.Fatal("stable target proof was lost across carrier reconnect")
				}
			}
			if scenario == "expired" {
				c.runtimeInventory.mu.Lock()
				cached := c.runtimeInventory.runtimes[target.key()]
				attempt := m.attempt(target.key())
				validUntil := int64Param(cached, "readiness_valid_until", 0)
				c.runtimeInventory.mu.Unlock()
				if validUntil <= attempt.expiresAt {
					t.Fatalf("operation expiry still capped native readiness: %d <= %d", validUntil, attempt.expiresAt)
				}
			}
			if scenario == "credential_changed" {
				binding.Method = "credential_import"
				if _, err := m.beginPrivateInput(target, binding); err != nil {
					t.Fatal(err)
				}
				m.invalidatePrivateVerification(target)
			}
			verifiedAt := int64(0)
			if scenario == "verified" {
				verifiedAt = int64Param(mapParam(m.status(context.Background(), target, "admin"), "auth"), "observed_at", 0)
				time.Sleep(2 * time.Millisecond)
			}
			if scenario != "wrong_backend" {
				// A later native probe is local only and cannot repeat a paid request.
				observed, err := c.runtimeInventory.probeOne(context.Background(), target, "operator")
				if err != nil {
					t.Fatal(err)
				}
				wantReady := scenario == "verified" || scenario == "concurrent_native_call" || scenario == "expired" || scenario == "reconnected_after_verify"
				if (observed["ready"] == true) != wantReady {
					t.Fatalf("stale/wrong-backend proof: %#v", observed)
				}
				if calls.Load() != wantCalls {
					t.Fatal("status/probe repeated verification")
				}
				if scenario == "verified" && int64Param(mapParam(observed, "auth"), "observed_at", 0) != verifiedAt {
					t.Fatal("local probe rewrote the provider verification time")
				}
			}
			if scenario == "expired" {
				deadline := time.Now().Add(2 * time.Second)
				for m.attempt(target.key()) != nil && time.Now().Before(deadline) {
					time.Sleep(10 * time.Millisecond)
				}
				status := m.status(context.Background(), target, "admin")
				if status["dispatch_ready"] != true || stringParam(mapParam(status, "auth"), "status") != "authenticated" {
					t.Fatalf("operation expiry retired current verification: %#v", status)
				}
			}
			if attempt := m.attempt(target.key()); attempt != nil {
				unlock := m.lockTarget(target.key())
				m.removeAttemptIfCurrent(target.key(), attempt)
				unlock()
			}
		})
	}
}
