package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func managedDelivery(account, endpoint, protocol, scheme, key, version string, revision int64) map[string]any {
	return map[string]any{
		"bound": true, "credential_kind": "provider_api_key", "subscription_account_id": account,
		"connection": map[string]any{"endpoint": endpoint, "protocol": protocol, "auth_scheme": scheme},
		"api_key":    key, "account_version": version, "delivery_revision": revision,
	}
}

func TestManagedRuntimeDeliveryIsTypedFencedAndIdempotent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, key := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
		t.Setenv(key, "")
	}
	c, err := newConnector(config{name: "managed-delivery", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	target := runtimeProbeTarget{provider: "claude", identityMaterial: fakeClaudeRuntimeCommand(t)}
	m := c.runtimeAuthCoordinator()
	first := managedDelivery("account-a", "https://models.example/v1", "anthropic_messages", "bearer", "secret-a", "v1", 1)
	unlock := m.lockTarget(target.key())
	if err := m.applyManagedDeliveryLocked(context.Background(), target, first); err != nil {
		unlock()
		t.Fatal(err)
	}
	installed := m.managedCredential(target)
	unlock()

	repeat := managedDelivery("account-a", "https://models.example/v1", "anthropic_messages", "bearer", "secret-a", "name-only-v2", 2)
	unlock = m.lockTarget(target.key())
	if err := m.applyManagedDeliveryLocked(context.Background(), target, repeat); err != nil {
		unlock()
		t.Fatal(err)
	}
	updated := m.managedCredential(target)
	unlock()
	if installed == updated || updated.accountVersion != "name-only-v2" {
		t.Fatal("repeat delivery did not advance the immutable account snapshot")
	}
	if updated.apiKey != "secret-a" {
		t.Fatal("repeat delivery changed the key")
	}

	for _, invalid := range []map[string]any{
		managedDelivery("account-b", "https://models.example/v1", "anthropic_messages", "bearer", "secret-a", "v3", 3),
		managedDelivery("account-a", "http://models.example/v1", "anthropic_messages", "bearer", "secret-a", "v3", 3),
		managedDelivery("account-a", "https://models.example/v1", "openai_responses", "bearer", "secret-a", "v3", 3),
	} {
		unlock = m.lockTarget(target.key())
		err := m.applyManagedDeliveryLocked(context.Background(), target, invalid)
		unlock()
		if err == nil {
			t.Fatal("invalid or conflicting managed credential was accepted")
		}
	}
	unlock = m.lockTarget(target.key())
	if err := m.applyManagedDeliveryLocked(context.Background(), target, repeat); err == nil {
		unlock()
		t.Fatal("stale delivery revision was accepted")
	}
	unlock()
}

func TestManagedDeliveryRejectsOnlyPersonalNativeCredentials(t *testing.T) {
	writeFile := func(name, content string) func(*testing.T, string) {
		return func(t *testing.T, directory string) {
			if err := os.WriteFile(filepath.Join(directory, name), []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, test := range []struct {
		name         string
		provider     string
		configEnv    string
		command      func(*testing.T) string
		seed         func(*testing.T, string)
		wantConflict bool
	}{
		{
			name: "Claude native OAuth credentials", provider: "claude", configEnv: "CLAUDE_CONFIG_DIR", command: fakeClaudeRuntimeCommand,
			seed: writeFile(".credentials.json", `{"claudeAiOauth":{"accessToken":"personal"}}`), wantConflict: true,
		},
		{
			name: "Claude native settings auth token", provider: "claude", configEnv: "CLAUDE_CONFIG_DIR", command: fakeClaudeRuntimeCommand,
			seed: writeFile("settings.json", `{"env":{"ANTHROPIC_AUTH_TOKEN":"personal"}}`), wantConflict: true,
		},
		{
			name: "Claude config directory without credentials", provider: "claude", configEnv: "CLAUDE_CONFIG_DIR", command: fakeClaudeRuntimeCommand,
			seed: func(*testing.T, string) {},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			for _, key := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
				t.Setenv(key, "")
			}
			command := test.command(t)
			directory := t.TempDir()
			t.Setenv(test.configEnv, directory)
			test.seed(t, directory)
			c, err := newConnector(config{name: "managed-native-credentials", root: t.TempDir(), systemInfoInterval: 0})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeRuntimes()
			target := runtimeProbeTarget{provider: test.provider, identityMaterial: command}
			m := c.runtimeAuthCoordinator()
			unlock := m.lockTarget(target.key())
			err = m.applyManagedDeliveryLocked(context.Background(), target,
				managedDelivery("account", "https://models.example", "anthropic_messages", "api_key", "managed", "v1", 1))
			unlock()
			if test.wantConflict {
				if err == nil || !strings.Contains(err.Error(), "personal credential conflict") {
					t.Fatalf("managed delivery returned %v, want personal credential conflict", err)
				}
			} else if err != nil {
				t.Fatalf("managed delivery was blocked: %v", err)
			}
		})
	}
}

func TestManagedClaudeOAuthRefreshKeepsAccount(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, key := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
		t.Setenv(key, "")
	}
	c, err := newConnector(config{name: "claude-oauth", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	target := runtimeProbeTarget{provider: "claude", identityMaterial: fakeClaudeRuntimeCommand(t)}
	owner := c.runtimeAuthCoordinator()
	delivery := map[string]any{"credential_kind": "subscription_oauth", "subscription_account_id": "oauth-account", "account_version": "v1", "delivery_revision": int64(1), "access_token": "test-oauth-1", "expires_at": testFarFuture.Unix()}
	apply := func() error {
		unlock := owner.lockTarget(target.key())
		defer unlock()
		return owner.applyManagedDeliveryLocked(context.Background(), target, delivery)
	}
	if err := apply(); err != nil {
		t.Fatal(err)
	}
	if credential := owner.managedCredential(target); credential == nil || !credential.oauth || credential.apiKey != "test-oauth-1" {
		t.Fatal("OAuth delivery was not installed")
	}
	delivery["access_token"], delivery["account_version"], delivery["delivery_revision"] = "test-oauth-2", "v2", int64(2)
	if err := apply(); err != nil {
		t.Fatal(err)
	}
	if owner.managedCredential(target).apiKey != "test-oauth-2" {
		t.Fatal("refresh did not install new access")
	}
	delivery["subscription_account_id"], delivery["delivery_revision"] = "other-account", int64(3)
	if err := apply(); err == nil {
		t.Fatal("refresh silently switched account")
	}
}

func TestClaudeComputeOAuthRejectsForeignSealedScope(t *testing.T) {
	c, err := newConnector(config{name: "claude-sealed-scope", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	configureSubscriptionCompute(c)
	c.cfg.computeRuntimeProvider = "claude"
	command := fakeClaudeRuntimeCommand(t)
	for _, field := range []string{"tenant", "project", "workload", "instance", "generation", "epoch", "provider", "nonce", "current"} {
		t.Run(field, func(t *testing.T) {
			off := activateRuntimeTransportForTest(c, func(request message) error {
				if request.Method != "runtime_subscription_access" {
					return nil
				}
				original := c.cfg
				switch field {
				case "tenant":
					c.cfg.computeRuntimeTenantID = "other"
				case "project":
					c.cfg.computeRuntimeProjectID = "other"
				case "workload":
					c.cfg.computeRuntimeWorkloadID = "other"
				case "instance":
					c.cfg.computeRuntimeInstanceID = "other"
				case "generation":
					c.cfg.computeRuntimeGeneration++
				case "epoch":
					c.cfg.computeRuntimeEpoch = "other"
				case "provider":
					c.cfg.computeRuntimeProvider = "codex"
				case "nonce":
					request.Params["nonce"] = strings.Repeat("b", 32)
				}
				access := map[string]any{"bound": true, "credential_kind": "subscription_oauth", "subscription_account_id": "account", "access_token": "sealed-access", "account_version": "v1", "delivery_revision": int64(1), "expires_at": testFarFuture.Unix()}
				envelope := sealComputeSubscriptionTest(t, c, request, access)
				c.cfg = original
				c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: envelope})
				return nil
			})
			defer off()
			access, err := c.subscriptionAccess(context.Background(), c.getActiveTransport(), command, "")
			if field == "current" {
				if err != nil || access["access_token"] != "sealed-access" {
					t.Fatal("current Compute scope could not receive its access token")
				}
			} else if err == nil {
				t.Fatal("foreign sealed scope yielded an access token")
			}
		})
	}
}
