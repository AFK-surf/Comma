package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
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

func decodeRuntimeAuthInput(data []byte) (runtimeAuthInputEnvelope, error) {
	if len(data) == 0 || len(data) > runtimeAuthEnvelopeLimit {
		return runtimeAuthInputEnvelope{}, errRuntimeAuthInputInvalid
	}
	fields, err := runtimeAuthJSONObject(data, "enc", "ciphertext")
	if err != nil || len(fields) != 2 {
		return runtimeAuthInputEnvelope{}, errRuntimeAuthInputInvalid
	}
	var envelope runtimeAuthInputEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return runtimeAuthInputEnvelope{}, errRuntimeAuthInputInvalid
	}
	if len(envelope.EncapsulatedKey) != 65 || len(envelope.Ciphertext) < 16 || len(envelope.Ciphertext) > runtimeAuthPlaintextLimit+16 {
		return runtimeAuthInputEnvelope{}, errRuntimeAuthInputInvalid
	}
	return envelope, nil
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
	context         runtimeAuthInputContext
	key             *runtimeAuthInputKey
	publicKey       []byte
	phase           string
	outcome         runtimeAuthSaveOutcome
	timer           *time.Timer
	verifyCancel    context.CancelFunc
	claudeLogin     *runtimeAuthClaudeLogin
	verificationURL string
}

func (attempt *runtimeAuthAttempt) destroyInput() {
	if attempt.input == nil {
		return
	}
	attempt.input.key.destroy()
	if attempt.input.verifyCancel != nil {
		attempt.input.verifyCancel()
	}
	if attempt.input.claudeLogin != nil {
		attempt.input.claudeLogin.close()
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
	// The authorized carrier supplies target facts; input cannot select a provider
	// or native path. Additional static adapters add their own fixed forms here.
	computeOwner := false
	if m.codex != nil && m.codex.connector != nil {
		c := m.codex.connector
		computeOwner = c.cfg.runtimeAgent && c.cfg.computeRuntimeKind == "external_worker" &&
			c.cfg.computeRuntimeProvider == binding.Provider && binding.TargetKind == "compute_workload"
	}
	supportedForm := computeOwner && binding.Provider == "pi" && binding.Backend == "openrouter" && (binding.Form == "pi_auth_entry" || binding.Form == "api_key")
	if binding.Provider == "codex" && ((binding.Form == "codex_auth_file" && (binding.Backend == "chatgpt" || binding.Backend == "openai")) || (binding.Form == "api_key" && binding.Backend == "openai")) {
		// File replacement requires the workload deployment's native-writer
		// ownership. A connected user CLI can have independent writers.
		supportedForm = m.codex != nil && m.codex.connector != nil && m.codex.connector.cfg.runtimeAgent &&
			m.codex.connector.cfg.computeRuntimeKind == "external_worker" &&
			m.codex.connector.cfg.computeRuntimeProvider == "codex" && binding.TargetKind == "compute_workload"
	}
	if binding.Provider == "claude" && ((binding.Backend == "anthropic" &&
		(binding.Form == "api_key" || binding.Form == "claude_backend_config" || binding.Form == "claude_credentials_file")) ||
		(binding.Backend == "openrouter" && (binding.Form == "api_key" || binding.Form == "claude_backend_config"))) {
		// Settings replacement is advertised only inside the workload deployment
		// that owns every Claude child and its stable provider_state volume.
		supportedForm = computeOwner
	}
	verification := binding.Method == "verify" && binding.Form == "api_key" &&
		(binding.Provider == "pi" && binding.Backend == "openrouter" ||
			binding.Provider == "claude" && (binding.Backend == "anthropic" || binding.Backend == "openrouter"))
	claudeLogin := computeOwner && binding.Provider == "claude" && binding.Backend == "anthropic" &&
		binding.Method == "native_login" && binding.Form == "authorization_code"
	if binding.ActorID == "" || binding.Provider != target.provider || (!verification && !claudeLogin && (!supportedForm || binding.Method != "credential_import")) || binding.SchemaVersion != 1 {
		return nil, errRuntimeAuthInputInvalid
	}
	binding.AttemptID = randomHex(16)
	binding.Sequence = 1
	binding.ExpiresAt = uint64(m.now().Add(m.ttl).UnixMilli())
	if _, err := binding.aad(); err != nil {
		return nil, err
	}
	var key *runtimeAuthInputKey
	var public []byte
	if !verification {
		var err error
		key, public, err = newRuntimeAuthInputKey()
		if err != nil {
			return nil, err
		}
	}
	attempt := &runtimeAuthAttempt{probeTarget: target, attemptID: binding.AttemptID, expiresAt: int64(binding.ExpiresAt), input: &runtimeAuthPrivateInput{context: binding, key: key, publicKey: public, phase: "awaiting_user", outcome: runtimeAuthSaveOutcome{SaveResult: "not_committed"}}}
	m.mu.Lock()
	if len(m.attempts) >= runtimeAuthConcurrency {
		m.mu.Unlock()
		key.destroy()
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

// Receive and Commit map to tla/connector/RuntimeAuthInput.tla. The authorized
// carrier must re-evaluate its live delegation in current, including expiry,
// connection, allocation, and runtime generations and target identity. It runs inside the final
// target section, never as a cached promise made before SDK preparation.
func (m *runtimeAuthCoordinator) savePrivatePi(ctx context.Context, target runtimeProbeTarget, expected runtimeAuthInputContext, envelope runtimeAuthInputEnvelope, nodePath, sdkEntry, authPath string, current func() bool) runtimeAuthSaveOutcome {
	return m.savePrivateInput(ctx, target, expected, envelope, current, func(data []byte, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
		entry, err := parseRuntimeAuthPiEntry(data)
		if err != nil {
			return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
		}
		return saveRuntimeAuthPi(ctx, nodePath, sdkEntry, authPath, entry, commit)
	}, func(stage string) runtimeAuthSaveOutcome {
		return commitRuntimeAuthFile(ctx, stage, authPath)
	})
}

// Static adapters prepare private bytes outside the target section. The shared
// owner consumes the envelope once and serializes the final commit with target
// admission, cancellation and receipt updates. commit runs under that section;
// a transport adapter must additionally hold its live carrier fence at rename.
func (m *runtimeAuthCoordinator) savePrivateInput(ctx context.Context, target runtimeProbeTarget, expected runtimeAuthInputContext, envelope runtimeAuthInputEnvelope, current func() bool, prepare func([]byte, func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	unlock := m.lockTarget(target.key())
	attempt := m.attempt(target.key())
	rejected := runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	if prepare == nil || commit == nil || attempt == nil || attempt.input == nil || attempt.input.context != expected || current == nil || !current() || attempt.expiresAt <= m.now().UnixMilli() {
		unlock()
		return rejected
	}
	input := attempt.input
	if input.phase != "awaiting_user" {
		result := input.outcome
		unlock()
		return result
	}
	if m.targetBusy(target) {
		unlock()
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "runtime_busy"}
	}
	input.phase = "receiving"
	aad, err := expected.aad()
	var plaintext []byte
	if err == nil {
		plaintext, err = input.key.open(envelope, aad)
	}
	input.key.destroy()
	if err != nil {
		input.phase = "failed"
		input.outcome = runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
		result := input.outcome
		unlock()
		return result
	}
	defer clear(plaintext)
	input.phase = "applying"
	input.outcome = runtimeAuthSaveOutcome{SaveResult: "unknown", Issue: "applying"}
	unlock()
	result := prepare(plaintext, func(stage string) runtimeAuthSaveOutcome {
		unlock := m.lockTarget(target.key())
		defer unlock()
		if m.attempt(target.key()) != attempt || input.phase != "applying" || attempt.expiresAt <= m.now().UnixMilli() || !current() {
			return rejected
		}
		if m.targetBusy(target) {
			return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "runtime_busy"}
		}
		m.clearPrivateVerification(target)
		m.codex.connector.runtimeInventory.updateAuthSnapshot(target, map[string]any{
			"schema_version": 1, "status": "unknown", "requires_openai_auth": false, "observed_at": m.now().UnixMilli(),
		}, false)
		input.outcome = commit(stage)
		return input.outcome
	})
	unlock = m.lockTarget(target.key())
	defer unlock()
	if m.attempt(target.key()) == attempt && input.phase == "applying" {
		input.outcome = result
		input.phase = "failed"
		if result.SaveResult == "committed" {
			input.phase = "completed"
			if (target.provider == "pi" || target.provider == "claude") && current() {
				m.codex.connector.runtimeInventory.updateAuthSnapshot(target, map[string]any{
					"schema_version": 1, "status": "configured", "requires_openai_auth": false,
					"observed_at": m.now().UnixMilli(), "backend": expected.Backend,
				}, false)
			}
		}
		if result.SaveResult == "unknown" {
			input.phase = "outcome_unknown"
		}
	}
	return result
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
	input.key.destroy()
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
// retirement maps it to RuntimeAuthInput.Restart: destroy volatile key/receipt
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
	native     *codexRuntime
	config     map[string]any
	authPath   string
	node       string
	sdk        string
	claude     *claudeRuntimeImplementation
}

func (c *connector) computePrivateRuntimeAuth(ctx context.Context, request message, session computeRuntimeSession, carrier *runtimeTransport) (map[string]any, error) {
	params, err := c.computeRuntimeAuthParams(map[string]any{"target": request.Params["target"]}, session)
	if err != nil {
		return nil, err
	}
	target := runtimeProbeTarget{provider: stringParam(params, "provider"), identityMaterial: stringParam(params, "identity_material")}
	wire := mapParam(request.Params, "target")
	binding := runtimeAuthInputContext{
		ActorID: stringParam(wire, "actor_id"), TenantID: c.cfg.computeRuntimeTenantID, ProjectID: c.cfg.computeRuntimeProjectID,
		TargetKind: "compute_workload", WorkloadID: c.cfg.computeRuntimeWorkloadID,
		RuntimeInstanceID: session.instance, Generation: strconv.Itoa(session.generation), ConnectionEpoch: session.epoch,
		AllocationID: stringParam(wire, "allocation_id"), AllocationGeneration: stringParam(wire, "allocation_generation"), Provider: target.provider,
	}
	return c.privateRuntimeAuth(ctx, request, target, binding, &runtimeAuthPrivateTarget{carrier: carrier})
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
	if target.provider == "claude" {
		c.runtimeInventory.mu.Lock()
		observedVersion := stringParam(c.runtimeInventory.runtimes[target.key()], "version")
		c.runtimeInventory.mu.Unlock()
		if !runtimeAuthClaudeVersionSupported(observedVersion) {
			return nil, errors.New("native auth version unsupported")
		}
	}
	if request.Method == "runtime_auth_login_start" {
		binding.Backend = stringParam(request.Params, "backend")
		flow := stringParam(request.Params, "flow")
		if target.provider == "codex" {
			if binding.Backend != "chatgpt" || flow != "device_code" {
				return nil, errRuntimeAuthInputInvalid
			}
			return m.startScoped(ctx, target, "device_code", &binding, local)
		}
		if target.provider != "claude" || binding.Backend != "anthropic" || flow != runtimeAuthClaudeLoginFlow {
			return nil, errRuntimeAuthInputInvalid
		}
		implementation, ok := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
		if !ok || implementation == nil {
			return nil, errors.New("native auth unavailable")
		}
		var locationErr error
		local.authPath, locationErr = runtimeAuthClaudeCredentialsLocation()
		if locationErr != nil {
			return nil, errors.New("native auth path unavailable")
		}
		local.claude = implementation
		binding.Method, binding.Form, binding.SchemaVersion = "native_login", runtimeAuthClaudeLoginFlow, 1
		binding.NativeGeneration, binding.AuthEpoch = implementation.authFence()
		return m.startPrivateClaudeLogin(ctx, target, binding, local)
	}
	if request.Method == "runtime_auth_input_begin" || request.Method == "runtime_auth_verify" {
		binding.Backend, binding.Form = stringParam(request.Params, "backend"), stringParam(request.Params, "form")
		binding.Method, binding.SchemaVersion = "credential_import", 1
		if request.Method == "runtime_auth_verify" {
			binding.Method, binding.Form = "verify", "api_key"
		}
		switch target.provider {
		case "codex":
			native, err := m.codex.ensureTargetRuntime(ctx, target)
			if err != nil {
				return nil, errors.New("native auth unavailable")
			}
			result, err := native.rpc(ctx, "config/read", map[string]any{"includeLayers": false}, 5*time.Second)
			if err != nil {
				return nil, errors.New("native auth policy unavailable")
			}
			config := mapParam(result, "config")
			local.config = map[string]any{}
			for _, key := range []string{"cli_auth_credentials_store", "forced_login_method", "forced_chatgpt_workspace_id"} {
				local.config[key] = config[key]
			}
			mode := "chatgpt"
			if binding.Backend == "openai" {
				mode = "apikey"
			}
			if issue := runtimeAuthCodexImportPolicy(local.config, runtimeAuthCodexFile{mode: mode}); issue != "" {
				return nil, errors.New(issue)
			}
			configPath := codexConfigPath()
			if configPath == "" {
				return nil, errors.New("native auth path unavailable")
			}
			local.authPath = filepath.Join(filepath.Dir(configPath), "auth.json")
			local.native = native
			m.codex.mu.Lock()
			binding.NativeGeneration = native.generation
			binding.AuthEpoch = strconv.FormatUint(native.authEpoch, 10)
			m.codex.mu.Unlock()
		case "pi":
			var err error
			local.node, local.sdk, local.authPath, err = runtimeAuthPiLocation(ctx, target.identityMaterial)
			if err != nil {
				return nil, errors.New("native auth path unavailable")
			}
		case "claude":
			implementation, ok := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
			if !ok || implementation == nil {
				return nil, errors.New("native auth unavailable")
			}
			var err error
			if binding.Form == "claude_credentials_file" {
				local.authPath, err = runtimeAuthClaudeCredentialsLocation()
			} else {
				local.authPath, err = runtimeAuthClaudeLocation()
			}
			if err != nil {
				return nil, errors.New("native auth path unavailable")
			}
			local.claude = implementation
			binding.NativeGeneration, binding.AuthEpoch = implementation.authFence()
		default:
			return nil, errors.New("native auth input unsupported")
		}
		if request.Method == "runtime_auth_verify" {
			if target.provider == "pi" && binding.Backend != "openrouter" ||
				target.provider == "claude" && binding.Backend != "anthropic" && binding.Backend != "openrouter" ||
				target.provider != "pi" && target.provider != "claude" {
				return nil, errRuntimeAuthInputInvalid
			}
			outcome := m.verifyPrivateTarget(ctx, target, binding, local, func() bool { return c.privateRuntimeAuthCurrent(ctx, local, binding) }, func(ctx context.Context, model string) runtimeAuthVerificationOutcome {
				if target.provider == "claude" {
					return verifyRuntimeAuthClaude(ctx, target.identityMaterial, binding.Backend, model)
				}
				return verifyRuntimeAuthPi(ctx, local.node, local.sdk, local.authPath, model)
			})
			return map[string]any{"status": outcome.Status, "issue": outcome.Issue}, nil
		}
		attempt, err := m.beginPrivateInput(target, binding)
		if err != nil {
			return nil, err
		}
		unlock := m.lockTarget(target.key())
		defer unlock()
		if m.attempt(target.key()) != attempt || attempt.input.phase != "awaiting_user" || !c.privateRuntimeAuthCurrent(ctx, local, binding) {
			m.removeAttemptIfCurrent(target.key(), attempt)
			return nil, errRuntimeAuthInputInvalid
		}
		attempt.target = local
		return map[string]any{"context": attempt.input.context, "public_key": attempt.input.publicKey, "phase": "awaiting_user", "save_result": "not_committed"}, nil
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
	if request.Method == "runtime_auth_input_cancel" {
		outcome := m.cancelPrivateInput(target, expected.AttemptID, current)
		return map[string]any{"save_result": outcome.SaveResult, "issue": outcome.Issue}, nil
	}
	// The authenticated carrier delegates project-admin cancellation. Submission
	// still belongs exclusively to the actor bound into the input offer's AAD.
	if request.Method != "runtime_auth_input_submit" || expected.ActorID != actor {
		return nil, errRuntimeAuthInputInvalid
	}
	encoded, ok := request.Params["envelope"].(string)
	if !ok || len(encoded) > runtimeAuthEnvelopeLimit {
		return nil, errRuntimeAuthInputInvalid
	}
	// Preserve the original envelope JSON for duplicate/depth validation;
	// decoding it into the outer RPC map first would erase duplicate members.
	envelope, err := decodeRuntimeAuthInput([]byte(encoded))
	if err != nil {
		return nil, err
	}
	withCarrier := func(commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
		return c.commitPrivateRuntimeAuth(ctx, local, expected, commit)
	}
	var outcome runtimeAuthSaveOutcome
	if target.provider == "codex" {
		outcome = m.savePrivateCodex(ctx, target, expected, envelope, local.native, local.authPath, local.config, current, withCarrier)
	} else if target.provider == "claude" {
		if expected.Method == "native_login" {
			outcome = m.submitPrivateClaudeLogin(ctx, target, attempt, expected, envelope, local.claude, local.authPath, current, withCarrier)
		} else {
			outcome = savePrivateClaude(ctx, m, target, expected, envelope, local.claude, local.authPath, current, withCarrier)
		}
	} else {
		outcome = m.savePrivateInput(ctx, target, expected, envelope, current, func(data []byte, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
			if expected.Form == "api_key" {
				key, err := parseRuntimeAuthAPIKey(data)
				if err != nil {
					return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
				}
				data, _ = json.Marshal(runtimeAuthPiEntry{Type: "api_key", Key: key})
				defer clear(data)
			}
			entry, err := parseRuntimeAuthPiEntry(data)
			if err != nil {
				return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
			}
			return saveRuntimeAuthPi(ctx, local.node, local.sdk, local.authPath, entry, commit)
		}, func(stage string) runtimeAuthSaveOutcome {
			return withCarrier(func() runtimeAuthSaveOutcome { return commitRuntimeAuthFile(ctx, stage, local.authPath) })
		})
	}
	if target.provider == "claude" && outcome.SaveResult == "committed" && outcome.Issue == "" && current() {
		if runtimes, err := c.runtimeInventory.probe(ctx, target.provider, target.identityMaterial, "runtime_auth_apply"); err != nil || len(runtimes) != 1 {
			outcome.Issue = "native_refresh_failed"
		} else {
			c.publishCachedMetadata()
		}
	}
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
		"dispatch_ready": current && observed["ready"] == true && codexAuthSnapshotReady(auth),
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
			if input.context.ActorID == actor && input.context.Method == "native_login" && input.verificationURL != "" {
				view["ceremony"] = map[string]any{
					"verification_url": input.verificationURL, "user_code": "",
					"input": map[string]any{"context": input.context, "public_key": input.publicKey, "phase": "awaiting_user", "save_result": "not_committed"},
				}
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
		c := m.codex.connector
		if c.cfg.runtimeAgent && c.cfg.computeRuntimeKind == "external_worker" && c.cfg.computeRuntimeProvider == "codex" {
			native, err := m.codex.ensureTargetRuntime(ctx, target)
			if err == nil {
				policy, err := native.rpc(ctx, "config/read", map[string]any{"includeLayers": false}, 5*time.Second)
				if err == nil {
					for _, mode := range []string{"chatgpt", "apikey"} {
						if runtimeAuthCodexImportPolicy(mapParam(policy, "config"), runtimeAuthCodexFile{mode: mode}) == "" {
							backend := "chatgpt"
							if mode == "apikey" {
								backend = "openai"
							}
							add(backend, "credential_import", "codex_auth_file")
							if backend == "openai" {
								add(backend, "credential_import", "api_key")
							}
						}
					}
				}
			}
		}
	case "pi":
		if _, _, _, err := runtimeAuthPiLocation(ctx, target.identityMaterial); err == nil {
			c := m.codex.connector
			computeOwner := c.cfg.runtimeAgent && c.cfg.computeRuntimeKind == "external_worker" &&
				c.cfg.computeRuntimeProvider == "pi" && scope.TargetKind == "compute_workload"
			if computeOwner {
				add("openrouter", "credential_import", "pi_auth_entry")
				add("openrouter", "credential_import", "api_key")
			}
			add("openrouter", "verify", "api_key")
		}
	case "claude":
		c := m.codex.connector
		_, implementationPresent := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
		computeOwner := c.cfg.runtimeAgent && c.cfg.computeRuntimeKind == "external_worker" && c.cfg.computeRuntimeProvider == "claude" && scope.TargetKind == "compute_workload"
		versionSupported := runtimeAuthClaudeVersionSupported(stringParam(observed, "version"))
		if implementationPresent && versionSupported && computeOwner {
			if _, err := runtimeAuthClaudeCredentialsLocation(); err == nil {
				add("anthropic", "native_login", runtimeAuthClaudeLoginFlow)
			}
			if _, err := runtimeAuthClaudeLocation(); err == nil {
				add("anthropic", "credential_import", "api_key")
				add("anthropic", "credential_import", "claude_backend_config")
				add("openrouter", "credential_import", "api_key")
				add("openrouter", "credential_import", "claude_backend_config")
			}
			if _, err := runtimeAuthClaudeCredentialsLocation(); err == nil {
				add("anthropic", "credential_import", "claude_credentials_file")
			}
		}
		if path, backend, err := runtimeAuthClaudeProfile(); versionSupported && err == nil && path != "" && backend == stringParam(auth, "backend") && stringParam(observed, "model") != "" {
			add(backend, "verify", "api_key")
		}
	}
	result["methods"] = methods
	return result
}

func parseRuntimeAuthAPIKey(data []byte) (string, error) {
	fields, err := runtimeAuthJSONObject(data, "key")
	var key string
	if err != nil || len(fields) != 1 || json.Unmarshal(fields["key"], &key) != nil || !runtimeAuthCodexToken(key) {
		return "", errRuntimeAuthInputInvalid
	}
	return key, nil
}
