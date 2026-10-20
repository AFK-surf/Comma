package main

import (
	"context"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

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
	if !oauth && (stringParam(params, "credential_kind") != "provider_api_key" || target.provider != "claude") {
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
	compatible := target.provider == "claude" && protocol == "anthropic_messages" && (authScheme == "bearer" || authScheme == "api_key")
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
	if m.managedPersonalConflict(ctx, target) {
		return errors.New("personal credential conflict")
	}
	if err := m.retireManagedGeneration(target); err != nil {
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
	}
	return false
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
	if err := m.retireManagedGeneration(target); err != nil {
		return err
	}
	m.mu.Lock()
	delete(m.managedCredentials, target.key())
	m.mu.Unlock()
	return nil
}

// Managed Claude credentials are read per native call; no process holds an
// older generation. Other providers have no managed credential owner.
func (m *runtimeAuthCoordinator) retireManagedGeneration(target runtimeProbeTarget) error {
	if _, ok := m.codex.connector.runtimeImplementations[target.provider].(*claudeRuntimeImplementation); ok {
		return nil
	}
	return errSubscriptionUnavailable
}
