package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const managedRuntimeAPIKeyEnv = "SALIX_MANAGED_PROVIDER_API_KEY"
const managedPiAuthFileLimit = 1 << 20

type managedRuntimeCredential struct {
	revoked        bool
	oauth          bool
	accountID      string
	accountVersion string
	endpoint       string
	protocol       string
	authScheme     string
	apiKey         string
	revision       int64
}

func (c *managedRuntimeCredential) sameConfiguration(other *managedRuntimeCredential) bool {
	return c != nil && other != nil && c.accountID == other.accountID && c.endpoint == other.endpoint &&
		c.protocol == other.protocol && c.authScheme == other.authScheme && c.apiKey == other.apiKey && c.oauth == other.oauth
}

func managedRuntimeCredentialFromDelivery(target runtimeProbeTarget, params map[string]any) (*managedRuntimeCredential, error) {
	oauth := target.provider == "claude" && stringParam(params, "credential_kind") == "subscription_oauth"
	if !oauth && (stringParam(params, "credential_kind") != "provider_api_key" || (target.provider != "pi" && target.provider != "claude")) {
		return nil, errSubscriptionUnavailable
	}
	account := strings.TrimSpace(stringParam(params, "subscription_account_id"))
	version := strings.TrimSpace(stringParam(params, "account_version"))
	key := stringParam(params, "api_key")
	connection := mapParam(params, "connection")
	if oauth {
		key = stringParam(params, "access_token")
		if int64Param(params, "expires_at", 0) <= time.Now().Unix()+30 {
			return nil, errSubscriptionUnavailable
		}
		connection = map[string]any{"endpoint": "https://api.anthropic.com", "protocol": "anthropic_messages", "auth_scheme": "bearer"}
	}
	if len(connection) != 3 || account == "" || len(account) > 256 || version == "" || len(version) > 256 ||
		key == "" || len(key) > runtimeAuthPlaintextLimit || !utf8.ValidString(key) || containsManagedControl(key) {
		return nil, errSubscriptionUnavailable
	}
	endpoint := stringParam(connection, "endpoint")
	protocol := stringParam(connection, "protocol")
	authScheme := stringParam(connection, "auth_scheme")
	parsed, err := url.Parse(endpoint)
	if err != nil || len(endpoint) > 2048 || !utf8.ValidString(endpoint) || containsManagedControl(endpoint) ||
		parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errSubscriptionUnavailable
	}
	compatible := target.provider == "pi" && ((protocol == "anthropic_messages" && (authScheme == "bearer" || authScheme == "api_key")) ||
		((protocol == "openai_completions" || protocol == "openai_responses") && authScheme == "bearer"))
	compatible = compatible || target.provider == "claude" && protocol == "anthropic_messages" && (authScheme == "bearer" || authScheme == "api_key")
	if !compatible {
		return nil, errSubscriptionUnavailable
	}
	return &managedRuntimeCredential{
		oauth: oauth, accountID: account, accountVersion: version, endpoint: endpoint, protocol: protocol,
		authScheme: authScheme, apiKey: key, revision: int64Param(params, "delivery_revision", 0),
	}, nil
}

func containsManagedControl(value string) bool {
	for _, r := range value {
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}

func (m *runtimeAuthCoordinator) managedCredential(target runtimeProbeTarget) *managedRuntimeCredential {
	m.mu.Lock()
	defer m.mu.Unlock()
	credential := m.managedCredentials[target.key()]
	if credential != nil && credential.revoked {
		return nil
	}
	return credential
}

func (c *connector) managedRuntimeCredential(provider, command string) *managedRuntimeCredential {
	if owner := c.runtimeAuthCoordinator(); owner != nil {
		return owner.managedCredential(runtimeProbeTarget{provider: provider, identityMaterial: command})
	}
	return nil
}

// Credential presence establishes configured access, not upstream model success.
// Match Compute readiness: override only the native credential probe, and retain
// version, startup, workspace, and observation-expiry failures.
func (c *connector) projectManagedRuntimeReadiness(runtime map[string]any) {
	provider := stringParam(runtime, "provider")
	if provider != "claude" || c.managedRuntimeCredential(provider, stringParam(runtime, "identity_material")) == nil {
		return
	}
	runtime["auth_ready"] = true
	runtime["auth"] = map[string]any{"schema_version": 1, "status": "authenticated", "requires_openai_auth": false, "observed_at": time.Now().UnixMilli()}
	issue := stringParam(runtime, "readiness_issue")
	if runtime["version_detected"] == true && runtime["native_server_startable"] == true && runtime["app_server_startable"] == true &&
		(issue == "" || issue == "authentication_required" || issue == "verification_required") {
		runtime["ready"] = true
		runtime["status"] = "available"
		delete(runtime, "readiness_issue")
		delete(runtime, "readiness_message")
		delete(runtime, "last_error")
	}
}

// applyManagedDeliveryLocked installs one immutable credential while the target
// section excludes other installation and admission decisions.
func (m *runtimeAuthCoordinator) applyManagedDeliveryLocked(ctx context.Context, target runtimeProbeTarget, params map[string]any) error {
	credential, err := managedRuntimeCredentialFromDelivery(target, params)
	if err != nil || credential.revision <= 0 {
		return errSubscriptionUnavailable
	}
	m.mu.Lock()
	previousRevision := m.subscriptionRevisions[target.key()]
	current := m.managedCredentials[target.key()]
	m.mu.Unlock()
	if credential.revision <= previousRevision {
		return errors.New("subscription delivery superseded")
	}
	if current != nil && current.revoked {
		current = nil
	}
	if current != nil {
		if !current.sameConfiguration(credential) {
			if !current.oauth || !credential.oauth || current.accountID != credential.accountID {
				return errors.New("subscription account conflict")
			}
			// A token refresh updates future native starts without interrupting
			// accepted work. Claude replaces an idle process before its next Send.

		}
		// Account version can change for a name-only edit. That does not alter
		// native connection behavior and must not retire a process.
		m.mu.Lock()
		m.managedCredentials[target.key()] = credential
		m.subscriptionRevisions[target.key()] = credential.revision
		m.mu.Unlock()
		return nil
	}
	if m.targetBusy(target) {
		return errors.New("runtime_busy")
	}
	if m.managedPersonalConflict(ctx, target) {
		return errors.New("personal credential conflict")
	}
	if err := m.retireManagedGeneration(ctx, target); err != nil {
		return err
	}
	m.mu.Lock()
	m.managedCredentials[target.key()] = credential
	m.subscriptionRevisions[target.key()] = credential.revision
	m.mu.Unlock()
	return nil
}

func (m *runtimeAuthCoordinator) managedPersonalConflict(ctx context.Context, target runtimeProbeTarget) bool {
	// Explicit inherited credentials are an independent user-selected source.
	// Managed installation does not erase or silently supersede them.
	switch target.provider {
	case "claude":
		for _, name := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
			if strings.TrimSpace(getenv(name, "")) != "" {
				return true
			}
		}
		if managedClaudeNativeAuthConflict() {
			return true
		}
		settings, _, err := runtimeAuthClaudeArgs()
		return err != nil || len(settings) != 0
	case "pi":
		// PI_CODING_AGENT_DIR selects Pi's persistent native state. The Compute
		// provider sets it for every Pi workload, so its presence is not proof of
		// a personal credential. The credential file at that resolved location is
		// the conflict authority. Managed processes still use an isolated
		// projection below the connector root.
		probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		_, _, authPath, err := runtimeAuthPiLocation(probeCtx, target.identityMaterial)
		if err == nil {
			return managedPiNativeAuthConflict(authPath)
		}
	}
	return false
}

func managedPiNativeAuthConflict(authPath string) bool {
	pathInfo, err := os.Lstat(authPath)
	if errors.Is(err, os.ErrNotExist) {
		return false
	}
	if err != nil || !pathInfo.Mode().IsRegular() || pathInfo.Size() > managedPiAuthFileLimit {
		return true
	}
	file, err := openManagedPiAuthFile(authPath)
	if err != nil {
		return true
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !os.SameFile(pathInfo, info) || !info.Mode().IsRegular() || info.Size() > managedPiAuthFileLimit {
		return true
	}
	data, err := io.ReadAll(io.LimitReader(file, managedPiAuthFileLimit+1))
	if err != nil || len(data) > managedPiAuthFileLimit {
		return true
	}
	var entries map[string]json.RawMessage
	if json.Unmarshal(data, &entries) != nil || entries == nil {
		return true
	}
	currentInfo, err := os.Lstat(authPath)
	if err != nil || !os.SameFile(info, currentInfo) {
		return true
	}
	return len(entries) != 0
}

func managedClaudeNativeAuthConflict() bool {
	settingsPath, err := runtimeAuthClaudeLocation()
	if err != nil {
		return true
	}
	directory := filepath.Dir(settingsPath)
	credentials := filepath.Join(directory, runtimeAuthClaudeCredentialsName)
	info, err := os.Stat(credentials)
	if err == nil && (!info.Mode().IsRegular() || info.Size() > 0) {
		return true
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return true
	}
	return managedClaudeConfigAuthConflict(directory)
}

func (m *runtimeAuthCoordinator) revokeManagedCredential(ctx context.Context, target runtimeProbeTarget, account string, revision int64) error {
	m.mu.Lock()
	if revision <= m.subscriptionRevisions[target.key()] {
		m.mu.Unlock()
		return errors.New("subscription delivery superseded")
	}
	current := m.managedCredentials[target.key()]
	if current != nil && current.accountID != account {
		m.mu.Unlock()
		return errors.New("subscription account conflict")
	}
	m.subscriptionRevisions[target.key()] = revision
	if current != nil {
		if target.provider == "claude" {
			tombstone := *current
			tombstone.revoked = true
			m.managedCredentials[target.key()] = &tombstone
		} else {
			delete(m.managedCredentials, target.key())
		}
	}
	m.mu.Unlock()
	if current == nil {
		return nil
	}
	if err := m.retireManagedGeneration(ctx, target); err != nil {
		return err
	}
	m.mu.Lock()
	delete(m.managedCredentials, target.key())
	m.mu.Unlock()
	return nil
}

func (m *runtimeAuthCoordinator) retireManagedGeneration(ctx context.Context, target runtimeProbeTarget) error {
	var wait <-chan struct{}
	switch implementation := m.codex.connector.runtimeImplementations[target.provider].(type) {
	case *piRuntimeImplementation:
		wait = implementation.retireAuthGeneration()
	case *claudeRuntimeImplementation:
		return implementation.retireManagedTarget(ctx, target.identityMaterial)
	default:
		return errSubscriptionUnavailable
	}
	timeout := m.nativeCancelTimeout
	if timeout <= 0 {
		timeout = runtimeAuthNativeCancelTimeout
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-wait:
		return nil
	case <-ctx.Done():
		return errSubscriptionUnavailable
	case <-timer.C:
		return errors.New("native_writer_unavailable")
	}
}

// Work and recovery admission re-read the authoritative binding. Installation
// and the native-call count are joined by the same target section, so a revoke
// cannot slip between confirmation and admission.
func (c *connector) enterRuntimeAuthNativeCallAdmitted(ctx context.Context, provider, command string) (func(), error) {
	m := c.runtimeAuthCoordinator()
	target := runtimeProbeTarget{provider: provider, identityMaterial: command}
	if m == nil {
		return func() {}, nil
	}
	managedConnected := provider == "claude" && (m.managedCredential(target) != nil || slices.Contains(managedRuntimeCommands(provider), command))
	managedCompute := computeRuntimeIdentityConfigured(c.cfg) && c.cfg.computeRuntimeKind == "external_worker" && (provider == "pi" || provider == "claude")
	if !managedCompute && !managedConnected {
		return m.enterNativeCall(target), nil
	}
	transport := c.getActiveTransport()
	result, err := c.subscriptionAccess(ctx, transport, command, "")
	if err != nil {
		return nil, errSubscriptionUnavailable
	}
	unlock := m.lockTarget(target.key())
	defer unlock()
	if result["bound"] == false {
		if m.managedCredential(target) != nil {
			return nil, errSubscriptionUnavailable
		}
	} else if result["revoked"] == true {
		if err := m.revokeManagedCredential(ctx, target, stringParam(result, "subscription_account_id"), int64Param(result, "delivery_revision", 0)); err != nil {
			return nil, err
		}
		return nil, errSubscriptionUnavailable
	} else if err := m.applyManagedDeliveryLocked(ctx, target, result); err != nil {
		return nil, err
	}
	m.mu.Lock()
	lock := m.locks[target.key()]
	lock.nativeCalls++
	m.mu.Unlock()
	return func() {
		m.mu.Lock()
		lock.nativeCalls--
		if lock.users == 0 && lock.nativeCalls == 0 {
			delete(m.locks, target.key())
		}
		m.mu.Unlock()
	}, nil
}
