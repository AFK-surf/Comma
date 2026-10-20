package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/cloudflare/circl/hpke"
	"github.com/cloudflare/circl/kem"
)

const (
	runtimeAuthInputDomain    = "comma.runtime-auth.input.v1"
	runtimeAuthPlaintextLimit = 64 << 10
	runtimeAuthEnvelopeLimit  = 96 << 10
)

var errRuntimeAuthInputInvalid = errors.New("runtime auth input is invalid")

// One input carries one HPKE Base message. Authorization, sequence consumption,
// expiry and current target fencing belong to the existing target auth owner.
// The carrier must bound the full serialized envelope before decoding it.
type runtimeAuthInputEnvelope struct {
	EncapsulatedKey []byte `json:"enc"`
	Ciphertext      []byte `json:"ciphertext"`
}

// The owner constructs this context from authenticated target facts. Strings
// encode as UTF-8 with a uint32 big-endian byte length in this fixed order;
// integers encode as unsigned decimal strings. No JSON key ordering is used.
type runtimeAuthInputContext struct {
	ActorID              string `json:"actor_id"`
	TenantID             string `json:"tenant_id"`
	ProjectID            string `json:"project_id"`
	TargetKind           string `json:"target_kind"`
	WorkloadID           string `json:"workload_id"`
	DeviceID             string `json:"device_id"`
	RuntimeID            string `json:"runtime_id"`
	Provider             string `json:"provider"`
	Backend              string `json:"backend"`
	Method               string `json:"method"`
	Form                 string `json:"form"`
	SchemaVersion        uint32 `json:"schema_version"`
	AttemptID            string `json:"attempt_id"`
	RuntimeInstanceID    string `json:"runtime_instance_id"`
	Generation           string `json:"generation"`
	ConnectionEpoch      string `json:"connection_epoch"`
	AllocationID         string `json:"allocation_id"`
	AllocationGeneration string `json:"allocation_generation"`
	NativeGeneration     string `json:"native_generation"`
	AuthEpoch            string `json:"auth_epoch"`
	Sequence             uint32 `json:"sequence"`
	ExpiresAt            uint64 `json:"expires_at"`
}

func (context runtimeAuthInputContext) aad() ([]byte, error) {
	fields := []string{
		runtimeAuthInputDomain, context.ActorID, context.TenantID, context.ProjectID,
		context.TargetKind, context.WorkloadID, context.DeviceID, context.RuntimeID,
		context.Provider, context.Backend, context.Method, context.Form,
		strconv.FormatUint(uint64(context.SchemaVersion), 10), context.AttemptID,
		context.RuntimeInstanceID, context.Generation, context.ConnectionEpoch,
		context.AllocationID, context.AllocationGeneration, context.NativeGeneration, context.AuthEpoch,
		strconv.FormatUint(uint64(context.Sequence), 10), strconv.FormatUint(context.ExpiresAt, 10),
	}
	var encoded []byte
	for _, field := range fields {
		if !utf8.ValidString(field) || len(field) > 8192 || len(encoded)+4+len(field) > 8192 {
			return nil, errRuntimeAuthInputInvalid
		}
		encoded = binary.BigEndian.AppendUint32(encoded, uint32(len(field)))
		encoded = append(encoded, field...)
	}
	return encoded, nil
}

// Use the standard JSON tokenizer to reject ambiguous members before decoding
// a provider schema. The browser and target must agree on exactly one value for
// each field. Sixteen container levels is the private-input resource contract;
// byte limits are enforced by the envelope and plaintext entry points.
func runtimeAuthJSONObject(data []byte, allowed ...string) (map[string]json.RawMessage, error) {
	if !utf8.Valid(data) {
		return nil, errRuntimeAuthInputInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		token, err := decoder.Token()
		if err != nil {
			return errRuntimeAuthInputInvalid
		}
		delimiter, container := token.(json.Delim)
		if !container {
			return nil
		}
		if depth >= 16 || (delimiter != '{' && delimiter != '[') {
			return errRuntimeAuthInputInvalid
		}
		seen := map[string]struct{}{}
		for decoder.More() {
			if delimiter == '{' {
				member, err := decoder.Token()
				name, ok := member.(string)
				if err != nil || !ok {
					return errRuntimeAuthInputInvalid
				}
				if _, duplicate := seen[name]; duplicate {
					return errRuntimeAuthInputInvalid
				}
				seen[name] = struct{}{}
			}
			if err := value(depth + 1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || (delimiter == '{' && closing != json.Delim('}')) || (delimiter == '[' && closing != json.Delim(']')) {
			return errRuntimeAuthInputInvalid
		}
		return nil
	}
	if err := value(0); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errRuntimeAuthInputInvalid
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		return nil, errRuntimeAuthInputInvalid
	}
	for name := range fields {
		permitted := false
		for _, candidate := range allowed {
			permitted = permitted || name == candidate
		}
		if !permitted {
			return nil, errRuntimeAuthInputInvalid
		}
	}
	return fields, nil
}

type runtimeAuthInputKey struct{ private kem.PrivateKey }

func newRuntimeAuthInputKey() (*runtimeAuthInputKey, []byte, error) {
	public, private, err := hpke.KEM_P256_HKDF_SHA256.Scheme().GenerateKeyPair()
	if err != nil {
		return nil, nil, errRuntimeAuthInputInvalid
	}
	encoded, err := public.MarshalBinary()
	if err != nil {
		return nil, nil, errRuntimeAuthInputInvalid
	}
	return &runtimeAuthInputKey{private: private}, encoded, nil
}

// open uses the owner's expected context, never a context supplied alongside
// the ciphertext. Each input has a fresh encapsulation and exactly one Open.
func (key *runtimeAuthInputKey) open(envelope runtimeAuthInputEnvelope, expectedContext []byte) ([]byte, error) {
	if key == nil || key.private == nil || len(envelope.EncapsulatedKey) != 65 || len(envelope.Ciphertext) < 16 || len(envelope.Ciphertext) > runtimeAuthPlaintextLimit+16 || len(expectedContext) == 0 {
		return nil, errRuntimeAuthInputInvalid
	}
	suite := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM)
	receiver, err := suite.NewReceiver(key.private, []byte(runtimeAuthInputDomain))
	if err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	opener, err := receiver.Setup(envelope.EncapsulatedKey)
	if err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	plaintext, err := opener.Open(envelope.Ciphertext, expectedContext)
	if err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	return plaintext, nil
}

func (key *runtimeAuthInputKey) destroy() {
	if key != nil {
		key.private = nil
	}
}

// This state is owned by runtimeAuthCoordinator's existing target lock. It
// contains only the input key and a bounded, non-secret operation receipt.
type runtimeAuthPrivateInput struct {
	context      runtimeAuthInputContext
	phase        string
	outcome      runtimeAuthSaveOutcome
	timer        *time.Timer
	verifyCancel context.CancelFunc
}

func (attempt *runtimeAuthAttempt) destroyInput() {
	if attempt.input == nil {
		return
	}
	if attempt.input.verifyCancel != nil {
		attempt.input.verifyCancel()
	}
	if attempt.input.timer != nil {
		attempt.input.timer.Stop()
	}
}

func (m *runtimeAuthCoordinator) beginPrivateInput(target runtimeProbeTarget, binding runtimeAuthInputContext) (*runtimeAuthAttempt, error) {
	unlock := m.lockTarget(target.key())
	defer unlock()
	if m.subscriptionOwned(target) {
		return nil, errors.New("runtime uses a subscription binding")
	}
	if expired := m.takeExpiredAttempt(target.key()); expired != nil {
		if expired.input == nil {
			m.retireExpiredAttempt(target, expired)
		}
	}
	if existing := m.attempt(target.key()); existing != nil {
		if existing.input == nil || existing.input.phase == "awaiting_user" || existing.input.phase == "receiving" || existing.input.phase == "applying" || existing.input.phase == "verifying" {
			return nil, errors.New("runtime auth mutation is active")
		}
		m.removeAttemptIfCurrent(target.key(), existing)
	}
	// The authorized carrier supplies target facts; input cannot select a
	// provider or native path. Only a Claude API-key verification starts here.
	verification := binding.Method == "verify" && binding.Form == "api_key" &&
		binding.Provider == "claude" && (binding.Backend == "anthropic" || binding.Backend == "openrouter")
	if binding.ActorID == "" || binding.Provider != target.provider || !verification || binding.SchemaVersion != 1 {
		return nil, errRuntimeAuthInputInvalid
	}
	binding.AttemptID = randomHex(16)
	binding.Sequence = 1
	binding.ExpiresAt = uint64(m.now().Add(m.ttl).UnixMilli())
	if _, err := binding.aad(); err != nil {
		return nil, err
	}
	attempt := &runtimeAuthAttempt{probeTarget: target, attemptID: binding.AttemptID, expiresAt: int64(binding.ExpiresAt), input: &runtimeAuthPrivateInput{context: binding, phase: "awaiting_user", outcome: runtimeAuthSaveOutcome{SaveResult: "not_committed"}}}
	m.mu.Lock()
	if len(m.attempts) >= runtimeAuthConcurrency {
		m.mu.Unlock()
		return nil, errors.New("runtime auth capacity exhausted")
	}
	m.attempts[target.key()] = attempt
	m.mu.Unlock()
	attempt.input.timer = time.AfterFunc(m.ttl, func() {
		unlock := m.lockTarget(target.key())
		defer unlock()
		m.removeAttemptIfCurrent(target.key(), attempt)
	})
	return attempt, nil
}

func (m *runtimeAuthCoordinator) cancelPrivateInput(target runtimeProbeTarget, attemptID string, authorized func() bool) runtimeAuthSaveOutcome {
	unlock := m.lockTarget(target.key())
	defer unlock()
	attempt := m.attempt(target.key())
	if authorized == nil || !authorized() || attempt == nil || attempt.input == nil || attempt.attemptID != attemptID {
		return runtimeAuthSaveOutcome{SaveResult: "unknown", Issue: "attempt_unavailable"}
	}
	input := attempt.input
	if input.outcome.SaveResult == "committed" || (input.context.Method == "verify" && input.phase != "verifying" && input.phase != "awaiting_user") {
		return input.outcome
	}
	if input.verifyCancel != nil {
		input.verifyCancel()
	}
	input.phase = "canceled"
	saveResult := "not_committed"
	if input.context.Method == "verify" {
		saveResult = "not_requested"
	}
	input.outcome = runtimeAuthSaveOutcome{SaveResult: saveResult, Issue: "canceled"}
	outcome := input.outcome
	// Cancellation is terminal. Retire the attempt before replying so the
	// following status read can prove to Router that no mutation remains active.
	m.removeAttemptIfCurrent(target.key(), attempt)
	return outcome
}

// An unfinished private mutation belongs to one exact carrier. Transport
// retirement restarts it: destroy volatile key/receipt
// state and cancel any provider work. A completed verification observation
// instead belongs to the stable runtime target in this Connector process; the
// carrier fence has already protected its publication.
func (m *runtimeAuthCoordinator) runtimeCarrierClosed(carrier *runtimeTransport) {
	if carrier == nil {
		return
	}
	type candidate struct {
		key     string
		attempt *runtimeAuthAttempt
	}
	candidates := make([]candidate, 0, runtimeAuthConcurrency)
	m.mu.Lock()
	for key, attempt := range m.attempts {
		if attempt != nil && attempt.input != nil && attempt.target != nil && attempt.target.carrier == carrier {
			candidates = append(candidates, candidate{key: key, attempt: attempt})
		}
	}
	m.mu.Unlock()
	for _, item := range candidates {
		unlock := m.lockTarget(item.key)
		attempt := m.attempt(item.key)
		if attempt == item.attempt && attempt.input != nil && attempt.target != nil && attempt.target.carrier == carrier {
			if m.acceptedPrivateVerificationCurrent(attempt.probeTarget) {
				unlock()
				continue
			}
			m.removeAttemptIfCurrent(item.key, attempt)
		}
		unlock()
	}
}

// The transport owner is the authority for this live delegation. Its exact
// captured instance (not merely a reused connection-epoch string) authorizes
// rename. activateRuntimeTransport/deactivation share sendMu, so replacement
// and commit have one order. A stale socket fails closed with old bytes intact.
// Callers already hold the target mutation lock; this callback never waits for
// provider work or sends a frame while holding sendMu.
func (c *connector) commitRuntimeAuthTransport(ctx context.Context, expected *runtimeTransport, commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if ctx.Err() != nil || expected == nil || c.activeTransport != expected || commit == nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	return commit()
}

// Captured, target-local adapter handles belong to the existing volatile attempt.
// Only non-secret policy fields are retained; no native config is relayed.
type runtimeAuthPrivateTarget struct {
	carrier    *runtimeTransport
	connection *connectionSession
}

func (c *connector) privateRuntimeAuth(ctx context.Context, request message, target runtimeProbeTarget, binding runtimeAuthInputContext, local *runtimeAuthPrivateTarget) (map[string]any, error) {
	allowed := map[string]bool{"target": true, "backend": true, "form": true, "attempt_id": true, "envelope": true, "flow": true}
	for key := range request.Params {
		if !allowed[key] {
			return nil, errRuntimeAuthInputInvalid
		}
	}
	carrier, actor := local.carrier, binding.ActorID
	if actor == "" || len(actor) > 256 || !c.privateRuntimeAuthCurrent(ctx, local, binding) {
		return nil, errRuntimeAuthInputInvalid
	}
	m := c.runtimeAuthCoordinator()
	if request.Method == "runtime_auth_status" {
		return m.statusScoped(ctx, target, binding), nil
	}
	if request.Method == "runtime_auth_login_start" {
		// Only Codex supports a remote device-code login on this carrier.
		binding.Backend = stringParam(request.Params, "backend")
		if target.provider != "codex" || binding.Backend != "chatgpt" || stringParam(request.Params, "flow") != "device_code" {
			return nil, errRuntimeAuthInputInvalid
		}
		return m.startScoped(ctx, target, "device_code", &binding, local)
	}
	if request.Method == "runtime_auth_verify" {
		// A connected runtime accepts an API key to verify only; the carrier
		// imports no credential.
		binding.Backend = stringParam(request.Params, "backend")
		binding.Method, binding.Form, binding.SchemaVersion = "verify", "api_key", 1
		if target.provider != "claude" || binding.Backend != "anthropic" && binding.Backend != "openrouter" {
			return nil, errRuntimeAuthInputInvalid
		}
		if implementation, ok := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation); !ok || implementation == nil {
			return nil, errors.New("native auth unavailable")
		}
		outcome := m.verifyPrivateTarget(ctx, target, binding, local, func() bool { return c.privateRuntimeAuthCurrent(ctx, local, binding) }, func(ctx context.Context, model string) runtimeAuthVerificationOutcome {
			return verifyRuntimeAuthClaude(ctx, target.identityMaterial, binding.Backend, model)
		})
		return map[string]any{"status": outcome.Status, "issue": outcome.Issue}, nil
	}
	if request.Method != "runtime_auth_input_cancel" {
		return nil, errRuntimeAuthInputInvalid
	}
	unlock := m.lockTarget(target.key())
	attempt := m.attempt(target.key())
	if request.Method == "runtime_auth_input_cancel" && attempt != nil && attempt.input == nil {
		defer unlock()
		if attempt.scope == nil || attempt.target == nil || attempt.attemptID != stringParam(request.Params, "attempt_id") || !sameRuntimeAuthTargetScope(*attempt.scope, binding) || !c.privateRuntimeAuthCurrent(ctx, attempt.target, *attempt.scope) {
			return nil, errRuntimeAuthInputInvalid
		}
		_, err := m.cancelLocked(ctx, target, attempt.attemptID)
		if err != nil {
			return nil, err
		}
		return map[string]any{"save_result": "not_requested", "issue": "canceled"}, nil
	}
	if attempt == nil || attempt.input == nil || attempt.target == nil || attempt.attemptID != stringParam(request.Params, "attempt_id") || !sameRuntimeAuthTargetScope(attempt.input.context, binding) || attempt.target.carrier != carrier {
		unlock()
		return nil, errRuntimeAuthInputInvalid
	}
	expected, local := attempt.input.context, attempt.target
	unlock()
	current := func() bool { return c.privateRuntimeAuthCurrent(ctx, local, expected) }
	outcome := m.cancelPrivateInput(target, expected.AttemptID, current)
	return map[string]any{"save_result": outcome.SaveResult, "issue": outcome.Issue}, nil
}

// Both target resolvers supply these exact product/transport facts on every
// action. Submission separately checks the original actor; admins may cancel.
func sameRuntimeAuthTargetScope(a, b runtimeAuthInputContext) bool {
	return a.TenantID == b.TenantID && a.ProjectID == b.ProjectID && a.TargetKind == b.TargetKind &&
		a.WorkloadID == b.WorkloadID && a.DeviceID == b.DeviceID && a.RuntimeID == b.RuntimeID &&
		a.Provider == b.Provider && a.RuntimeInstanceID == b.RuntimeInstanceID && a.Generation == b.Generation &&
		a.ConnectionEpoch == b.ConnectionEpoch && a.AllocationID == b.AllocationID && a.AllocationGeneration == b.AllocationGeneration
}

// Active-panel reads use the existing bounded owner and cached observation.
// They never probe the provider, refresh a token, or repeat a credential write.
func (m *runtimeAuthCoordinator) status(ctx context.Context, target runtimeProbeTarget, actor string) map[string]any {
	return m.statusScoped(ctx, target, runtimeAuthInputContext{ActorID: actor})
}

func (m *runtimeAuthCoordinator) statusScoped(ctx context.Context, target runtimeProbeTarget, scope runtimeAuthInputContext) map[string]any {
	actor := scope.ActorID
	unlock := m.lockTarget(target.key())
	defer unlock()
	now := m.now().UnixMilli()
	attempt := m.attempt(target.key())
	if m.privateVerification(target) != nil && !m.privateVerificationOwnerCurrent(target) {
		m.invalidatePrivateVerification(target)
	}
	inventory := m.codex.connector.runtimeInventory
	inventory.mu.Lock()
	observed := cloneRuntimeObservation(inventory.runtimes[target.key()])
	inventory.mu.Unlock()
	auth := mapParam(observed, "auth")
	if len(auth) == 0 {
		auth = map[string]any{"schema_version": 1, "status": "unknown", "requires_openai_auth": false, "observed_at": now}
	}
	current := int64Param(observed, "readiness_valid_until", 0) > now
	result := map[string]any{
		"provider": target.provider, "auth": auth,
		"native_ready":   current && observed["native_server_startable"] == true,
		"dispatch_ready": current && observed["ready"] == true && observed["auth_ready"] == true,
		"methods":        []map[string]any{}, "attempt": nil,
	}
	if attempt != nil && attempt.expiresAt > now {
		if attempt.input == nil && attempt.scope != nil && sameRuntimeAuthTargetScope(*attempt.scope, scope) && m.codex.connector.privateRuntimeAuthCurrent(ctx, attempt.target, scope) {
			owned := attempt.scope.ActorID == actor
			view := map[string]any{"attempt_id": attempt.attemptID, "expires_at": attempt.expiresAt, "owned": owned, "phase": "awaiting_user", "save_result": "not_requested", "issue": ""}
			if owned {
				view["ceremony"] = map[string]any{"verification_url": attempt.verificationURL, "user_code": attempt.userCode}
			}
			result["attempt"] = view
		}
		if attempt.input != nil {
			input := attempt.input
			view := map[string]any{
				"attempt_id": attempt.attemptID, "expires_at": attempt.expiresAt,
				"owned": input.context.ActorID == actor, "phase": input.phase,
				"save_result": input.outcome.SaveResult, "issue": input.outcome.Issue,
			}
			result["attempt"] = view
		}
		if attempt.input == nil || attempt.input.phase == "awaiting_user" || attempt.input.phase == "receiving" || attempt.input.phase == "applying" || attempt.input.phase == "verifying" {
			return result
		}
	}
	methods := []map[string]any{}
	add := func(backend, method, form string) {
		methods = append(methods, map[string]any{"backend": backend, "method": method, "form": form, "schema_version": 1})
	}
	switch target.provider {
	case "codex":
		add("chatgpt", "native_login", "device_code")
	case "claude":
		if path, backend, err := runtimeAuthClaudeProfile(); err == nil && path != "" && backend == stringParam(auth, "backend") && stringParam(observed, "model") != "" {
			add(backend, "verify", "api_key")
		}
	}
	result["methods"] = methods
	return result
}
