package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

var errSubscriptionUnavailable = errors.New("subscription access unavailable")

// The pool owns refresh credentials. Native processes receive access material
// only. All updates use the same target lock, including the native 401 callback.
func (c *connector) methodRuntimeAuthSubscription(ctx context.Context, session *connectionSession, params map[string]any) (map[string]any, error) {
	if err := c.acquireRuntimeAuth(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.runtimeAuthSlots }()
	target, err := c.runtimeCredentialTarget(params, "provider", "identity_material", "connector_run_id", "connection_generation", "credential_kind", "subscription_account_id", "access_token", "chatgpt_account_id", "expires_at", "credential_revision", "account_version", "connection", "api_key", "delivery_revision", "revoked", "require_idle")
	if err != nil {
		return nil, errSubscriptionUnavailable
	}
	current := func() bool {
		c.connectionMu.Lock()
		defer c.connectionMu.Unlock()
		return ctx.Err() == nil && session != nil && c.activeConnection == session && session.ctx.Err() == nil &&
			c.connectorRunID == stringParam(params, "connector_run_id") && c.connectionGeneration > 0 &&
			c.connectionGeneration == int64Param(params, "connection_generation", 0)
	}
	if !current() {
		return nil, errSubscriptionUnavailable
	}
	result, err := c.applySubscriptionDelivery(ctx, target, params, current)
	if err == nil && target.provider == "claude" && current() {
		_ = session.sendCtx(ctx, c.metadata())
	}
	return result, err
}

func (c *connector) applySubscriptionDelivery(ctx context.Context, target runtimeProbeTarget, params map[string]any, current func() bool) (map[string]any, error) {
	m := c.runtimeAuthCoordinator()
	if m == nil {
		return nil, errSubscriptionUnavailable
	}
	unlock := m.lockTarget(target.key())
	defer unlock()
	if !current() {
		return nil, errSubscriptionUnavailable
	}
	if m.attempt(target.key()) != nil || (params["require_idle"] == true && m.targetBusy(target)) {
		return nil, errors.New("runtime_busy")
	}

	revision := int64Param(params, "delivery_revision", 0)
	m.mu.Lock()
	if m.subscriptionRevisions == nil {
		m.subscriptionRevisions = map[string]int64{}
	}
	previous := m.subscriptionRevisions[target.key()]
	m.mu.Unlock()
	if revision <= previous {
		return nil, errors.New("subscription delivery superseded")
	}
	if params["revoked"] == true {
		if target.provider == "codex" {
			m.revokeSubscription(target, stringParam(params, "subscription_account_id"), revision)
		} else if err := m.revokeManagedCredential(ctx, target, stringParam(params, "subscription_account_id"), revision); err != nil {
			return nil, err
		}
		return map[string]any{"auth": codexAuthIssueSnapshot("auth_probe_failed", time.Now().UnixMilli())}, nil
	}
	if target.provider == "pi" || target.provider == "claude" {
		if err := m.applyManagedDeliveryLocked(ctx, target, params); err != nil {
			return nil, err
		}
		return map[string]any{"auth": map[string]any{"schema_version": 1, "status": "authenticated", "requires_openai_auth": false, "observed_at": time.Now().UnixMilli()}}, nil
	}
	if target.provider != "codex" || stringParam(params, "credential_kind") != "subscription_oauth" {
		return nil, errSubscriptionUnavailable
	}
	native, err := m.codex.ensureTargetRuntime(ctx, target)
	if err != nil {
		return nil, errSubscriptionUnavailable
	}
	if err = native.ensureInitialized(ctx); err != nil {
		return nil, errSubscriptionUnavailable
	}
	if err = native.applySubscription(ctx, params, current, false); err != nil {
		return nil, err
	}
	snapshot, err := m.codex.readRuntimeAuthSnapshotFromRuntime(ctx, native)
	if err != nil {
		m.codex.retireUnusableRuntimeGeneration(native)
		return nil, errSubscriptionUnavailable
	}
	m.publishSnapshotForRuntime(target, native, snapshot)
	return map[string]any{"auth": snapshot}, nil
}

func (c *connector) runtimeCredentialTarget(params map[string]any, allowedKeys ...string) (runtimeProbeTarget, error) {
	allowed := make(map[string]bool, len(allowedKeys))
	for _, key := range allowedKeys {
		allowed[key] = true
	}
	for key := range params {
		if !allowed[key] {
			return runtimeProbeTarget{}, errSubscriptionUnavailable
		}
	}
	provider := strings.TrimSpace(stringParam(params, "provider"))
	identity := strings.TrimSpace(stringParam(params, "identity_material"))
	if !computeExternalRuntimeProvider(provider) || identity == "" {
		return runtimeProbeTarget{}, errSubscriptionUnavailable
	}
	target, present := c.runtimeInventory.target(provider, identity)
	if !present {
		return runtimeProbeTarget{}, errSubscriptionUnavailable
	}
	return target, nil
}

// Called under the target lock after checking the delivery revision. Keep the
// fence on the coordinator: retiring a native generation must not erase it.
func (m *runtimeAuthCoordinator) revokeSubscription(target runtimeProbeTarget, account string, revision int64) {
	m.mu.Lock()
	if m.subscriptionRevisions == nil {
		m.subscriptionRevisions = map[string]int64{}
	}
	m.subscriptionRevisions[target.key()] = revision
	m.mu.Unlock()
	m.codex.mu.Lock()
	native := m.codex.runtimes[target.identityMaterial]
	m.codex.mu.Unlock()
	if native != nil {
		native.subscriptionMu.Lock()
		bound := native.subscriptionAccountID != "" && (native.subscriptionAccountID == account || !computeRuntimeIdentityConfigured(m.codex.connector.cfg))
		native.subscriptionMu.Unlock()
		if bound {
			m.codex.retireUnusableRuntimeGeneration(native)
		}
	}
}

// Called under the target lock. A database sequence orders deliveries across
// push, pull, reconnect, and multiple Salix nodes. It never identifies an account.
func (r *codexRuntime) applySubscription(ctx context.Context, params map[string]any, current func() bool, callback bool) error {
	account, chatgpt, access := stringParam(params, "subscription_account_id"), stringParam(params, "chatgpt_account_id"), stringParam(params, "access_token")
	revision := int64Param(params, "delivery_revision", 0)
	r.subscriptionMu.Lock()
	previousAccount, previousChatGPT := r.subscriptionAccountID, r.subscriptionChatGPTID
	previousRevision := r.subscriptionRevision
	previousCredential := r.subscriptionCredentialRevision
	needsLogin := r.subscriptionNeedsLogin
	r.subscriptionMu.Unlock()
	m := r.implementation.auth
	key := runtimeProbeTarget{provider: "codex", identityMaterial: r.command}.key()
	m.mu.Lock()
	latest := m.subscriptionRevisions[key]
	m.mu.Unlock()
	if latest > previousRevision {
		previousRevision = latest
	}
	if revision <= 0 || !current() {
		return errSubscriptionUnavailable
	}
	if revision <= previousRevision {
		return errors.New("subscription delivery superseded")
	}
	if previousAccount != "" && previousAccount != account && computeRuntimeIdentityConfigured(r.implementation.connector.cfg) {
		return errors.New("subscription account conflict")
	}
	if params["revoked"] == true {
		m.revokeSubscription(runtimeProbeTarget{provider: "codex", identityMaterial: r.command}, account, revision)
		return errSubscriptionUnavailable
	}
	if !runtimeAuthCodexToken(account) || len(account) > 256 || !runtimeAuthCodexToken(chatgpt) || len(chatgpt) > 256 ||
		!runtimeAuthCodexToken(access) || len(access) > runtimeAuthPlaintextLimit || int64Param(params, "expires_at", 0) <= time.Now().Unix()+30 {
		return errSubscriptionUnavailable
	}
	if previousChatGPT != "" && previousChatGPT != chatgpt && computeRuntimeIdentityConfigured(r.implementation.connector.cfg) {
		return errors.New("subscription account conflict")
	}
	if previousAccount == "" {
		// External tokens replace process authentication without changing persisted login.
		// Keep the provider check: this path supplies OpenAI subscription credentials.
		state, err := r.rpc(ctx, "account/read", map[string]any{"refreshToken": false}, 5*time.Second)
		if err != nil || state["requiresOpenaiAuth"] != true {
			return errors.New("subscription requires an OpenAI runtime")
		}
	}
	if !current() {
		return errSubscriptionUnavailable
	}
	if !callback && (needsLogin || previousAccount != account || previousChatGPT != chatgpt || previousCredential != stringParam(params, "credential_revision")) {
		_, err := r.rpc(ctx, "account/login/start", map[string]any{"type": "chatgptAuthTokens", "accessToken": access, "chatgptAccountId": chatgpt}, 10*time.Second)
		if err != nil || !current() {
			r.implementation.retireUnusableRuntimeGeneration(r)
			return errSubscriptionUnavailable
		}
	}
	m.mu.Lock()
	if m.subscriptionRevisions == nil {
		m.subscriptionRevisions = map[string]int64{}
	}
	m.subscriptionRevisions[key] = revision
	m.mu.Unlock()
	r.subscriptionMu.Lock()
	r.subscriptionAccountID, r.subscriptionChatGPTID = account, chatgpt
	r.subscriptionRevision = revision
	r.subscriptionCredentialRevision = stringParam(params, "credential_revision")
	r.subscriptionNeedsLogin = callback
	r.subscriptionMu.Unlock()
	return nil
}

func (c *connector) subscriptionAccess(ctx context.Context, transport *runtimeTransport, command, rejected string) (map[string]any, error) {
	return c.subscriptionAccessRequest(ctx, transport, command, rejected, false)
}

func (c *connector) subscriptionAccessRequest(ctx context.Context, transport *runtimeTransport, command, rejected string, admitted bool) (map[string]any, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	if transport == nil || !c.externalRuntimesEnabled() || c.currentScope() == scopeLocalFileRead {
		return nil, errSubscriptionUnavailable
	}
	if !admitted {
		if err := c.acquireRuntimeAuth(requestCtx); err != nil {
			return nil, errSubscriptionUnavailable
		}
		defer func() { <-c.runtimeAuthSlots }()
	}
	params := map[string]any{"identity_material": command}
	var key *runtimeAuthInputKey
	var aad []byte
	if computeRuntimeIdentityConfigured(c.cfg) {
		var err error
		key, params, aad, err = c.computeSubscriptionOffer()
		if err != nil {
			return nil, errSubscriptionUnavailable
		}
		defer key.destroy()
		if admitted {
			params["background"] = true
		}
	}
	if rejected != "" {
		params["rejected_revision"] = rejected
	}
	reply, err := c.sendRuntimeRequest(requestCtx, transport, nil, message{
		ID: c.nextRuntimeRequestID("subscription_"), Type: "request", Method: "runtime_subscription_access", Params: params,
	})
	if err != nil || reply.Type == "error" || reply.Error != "" || c.getActiveTransport() != transport {
		return nil, errSubscriptionUnavailable
	}
	result, ok := reply.Result.(map[string]any)
	if !ok {
		return nil, errSubscriptionUnavailable
	}
	if key != nil && !(len(result) == 1 && result["bound"] == false) {
		raw, err := json.Marshal(result)
		var envelope runtimeAuthInputEnvelope
		if err != nil || json.Unmarshal(raw, &envelope) != nil {
			return nil, errSubscriptionUnavailable
		}
		plaintext, err := key.open(envelope, aad)
		if err != nil {
			return nil, errSubscriptionUnavailable
		}
		defer clear(plaintext)
		result = nil
		if json.Unmarshal(plaintext, &result) != nil || result == nil {
			return nil, errSubscriptionUnavailable
		}
	}
	return result, nil
}

// One scoped read before new input or recovery. No credential reaches a session
// payload, the durable inbox, metadata, logs, or auth.json.
func (r *codexRuntime) ensureSubscription(ctx context.Context) error {
	c := r.implementation.connector
	transport := c.getActiveTransport()
	// Local provider probes have no server transport and cannot acquire a binding.
	if transport == nil {
		r.subscriptionMu.Lock()
		bound := r.subscriptionAccountID != ""
		r.subscriptionMu.Unlock()
		if bound || c.cfg.server != "" || c.cfg.deviceMode || computeRuntimeIdentityConfigured(c.cfg) {
			return errSubscriptionUnavailable
		}
		return nil
	}
	target := runtimeProbeTarget{provider: "codex", identityMaterial: r.command}
	unlock := r.implementation.auth.lockTarget(target.key())
	defer unlock()
	result, err := c.subscriptionAccess(ctx, transport, r.command, "")
	if err != nil {
		return err
	}
	r.subscriptionMu.Lock()
	bound := r.subscriptionAccountID != ""
	r.subscriptionMu.Unlock()
	if result["bound"] == false && !bound {
		return nil
	}
	if r.implementation.auth.attempt(target.key()) != nil {
		return errors.New("runtime_busy")
	}
	return r.applySubscription(ctx, result, func() bool { return ctx.Err() == nil && c.getActiveTransport() == transport && r.subscriptionCurrent() }, false)
}

// Native server requests must not block its read loop: that loop also receives
// login and thread RPC responses. At most one refresh runs per native process.
func (r *codexRuntime) refreshSubscription(id string, params map[string]any) {
	r.subscriptionMu.Lock()
	if r.subscriptionRefreshing || r.subscriptionAccountID == "" {
		r.subscriptionMu.Unlock()
		_ = r.writeCodexResponse(id, map[string]any{"error": map[string]any{"code": -32000, "message": "subscription refresh unavailable"}})
		return
	}
	r.subscriptionRefreshing = true
	r.subscriptionMu.Unlock()
	go func() {
		defer func() { r.subscriptionMu.Lock(); r.subscriptionRefreshing = false; r.subscriptionMu.Unlock() }()
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		c := r.implementation.connector
		target := runtimeProbeTarget{provider: "codex", identityMaterial: r.command}
		unlock := r.implementation.auth.lockTarget(target.key())
		defer unlock()
		r.subscriptionMu.Lock()
		rejected, account := r.subscriptionCredentialRevision, r.subscriptionChatGPTID
		r.subscriptionMu.Unlock()
		response := map[string]any{"error": map[string]any{"code": -32000, "message": "subscription refresh unavailable"}}
		transport := c.getActiveTransport()
		previous := stringParam(params, "previousAccountId")
		if params["reason"] == "unauthorized" && (previous == "" || previous == account) {
			result, err := c.subscriptionAccess(ctx, transport, r.command, rejected)
			if err == nil {
				err = r.applySubscription(ctx, result, func() bool { return ctx.Err() == nil && c.getActiveTransport() == transport && r.subscriptionCurrent() }, true)
			}
			if err == nil {
				response = map[string]any{"result": map[string]any{"accessToken": result["access_token"], "chatgptAccountId": result["chatgpt_account_id"]}}
			}
		}
		_ = r.writeCodexResponse(id, response)
	}()
}

func (r *codexRuntime) subscriptionCurrent() bool {
	i := r.implementation
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.runtimes[r.command] == r && r.isRunning()
}

func (m *runtimeAuthCoordinator) subscriptionOwned(target runtimeProbeTarget) bool {
	m.codex.mu.Lock()
	native := m.codex.runtimes[target.identityMaterial]
	m.codex.mu.Unlock()
	if native == nil {
		return false
	}
	native.subscriptionMu.Lock()
	defer native.subscriptionMu.Unlock()
	return native.subscriptionAccountID != ""
}
