package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func managedDelivery(account, endpoint, protocol, scheme, key, version string, revision int64) map[string]any {
	return map[string]any{
		"bound": true, "credential_kind": "provider_api_key", "subscription_account_id": account,
		"connection": map[string]any{"endpoint": endpoint, "protocol": protocol, "auth_scheme": scheme},
		"api_key":    key, "account_version": version, "delivery_revision": revision,
	}
}

func fakePiRuntimeAuthCommand(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "dist")
	if err := os.MkdirAll(filepath.Join(root, "bundle"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(root, "index.js"),
		[]byte(`export function getAgentDir(){ return process.env.PI_CODING_AGENT_DIR; }`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	command := filepath.Join(root, "bundle", "cli.js")
	if err := os.WriteFile(command, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	return command
}

func TestManagedRuntimeDeliveryIsTypedFencedAndIdempotent(t *testing.T) {
	c, err := newConnector(config{name: "managed-delivery", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	t.Setenv("PI_CODING_AGENT_DIR", "")
	target := runtimeProbeTarget{provider: "pi", identityMaterial: fakePortableRuntimeCommand(t, "pi")}
	m := c.runtimeAuthCoordinator()
	first := managedDelivery("account-a", "https://models.example/v1", "openai_completions", "bearer", "secret-a", "v1", 1)
	unlock := m.lockTarget(target.key())
	if err := m.applyManagedDeliveryLocked(context.Background(), target, first); err != nil {
		unlock()
		t.Fatal(err)
	}
	installed := m.managedCredential(target)
	unlock()

	repeat := managedDelivery("account-a", "https://models.example/v1", "openai_completions", "bearer", "secret-a", "name-only-v2", 2)
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
		managedDelivery("account-b", "https://models.example/v1", "openai_completions", "bearer", "secret-a", "v3", 3),
		managedDelivery("account-a", "http://models.example/v1", "openai_completions", "bearer", "secret-a", "v3", 3),
		managedDelivery("account-a", "https://models.example/v1", "openai_responses", "api_key", "secret-a", "v3", 3),
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

func TestConnectedManagedClaudeRequiresServerAdmission(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	c, err := newConnector(config{name: "connected-managed-admission", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "claude", identityMaterial: fakeClaudeRuntimeCommand(t)}
	owner := c.runtimeAuthCoordinator()
	unlock := owner.lockTarget(target.key())
	err = owner.applyManagedDeliveryLocked(context.Background(), target,
		managedDelivery("account", "https://models.example", "anthropic_messages", "api_key", "test-key", "v1", 1))
	unlock()
	if err != nil {
		t.Fatal(err)
	}
	leave, err := c.enterRuntimeAuthNativeCallAdmitted(context.Background(), target.provider, target.identityMaterial)
	if leave != nil {
		leave()
	}
	if !errors.Is(err, errSubscriptionUnavailable) {
		t.Fatalf("offline connected runtime admitted managed credentials: %v", err)
	}
}

func TestManagedClaudeWorkspaceAuthConflictIsExplicit(t *testing.T) {
	workspace := t.TempDir()
	settingsDir := filepath.Join(workspace, ".claude")
	if err := os.MkdirAll(settingsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(settingsDir, "settings.json"), []byte(`{"permissions":{"allow":["Read"]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if managedClaudeWorkspaceConflict(workspace) {
		t.Fatal("non-auth Claude settings were rejected")
	}
	if err := os.WriteFile(filepath.Join(settingsDir, "settings.local.json"), []byte(`{"env":{"ANTHROPIC_AUTH_TOKEN":"personal"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !managedClaudeWorkspaceConflict(workspace) {
		t.Fatal("workspace credential could override the managed Claude selection")
	}
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
			name: "Pi provider-owned directory without credentials", provider: "pi", configEnv: "PI_CODING_AGENT_DIR", command: fakePiRuntimeAuthCommand,
			seed: func(*testing.T, string) {},
		},
		{
			name: "Pi empty native auth placeholder", provider: "pi", configEnv: "PI_CODING_AGENT_DIR", command: fakePiRuntimeAuthCommand,
			seed: writeFile("auth.json", "{}"),
		},
		{
			name: "Pi symlinked empty auth placeholder", provider: "pi", configEnv: "PI_CODING_AGENT_DIR", command: fakePiRuntimeAuthCommand,
			seed: func(t *testing.T, directory string) {
				target := filepath.Join(t.TempDir(), "auth.json")
				if err := os.WriteFile(target, []byte("{}"), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, filepath.Join(directory, "auth.json")); err != nil {
					t.Fatal(err)
				}
			},
			wantConflict: true,
		},
		{
			name: "Pi personal credential in provider-owned directory", provider: "pi", configEnv: "PI_CODING_AGENT_DIR", command: fakePiRuntimeAuthCommand,
			seed: writeFile("auth.json", `{"anthropic":{"type":"api_key","key":"personal"}}`), wantConflict: true,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			command := test.command(t)
			directory := t.TempDir()
			t.Setenv(test.configEnv, directory)
			test.seed(t, directory)
			c, err := newConnector(config{name: "managed-native-credentials", root: t.TempDir(), systemInfoInterval: 0})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
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

func TestManagedPiEnvironmentClearsConflictingProviderCredentials(t *testing.T) {
	t.Setenv("OPENAI_API_KEY", "personal-openai")
	t.Setenv("ANTHROPIC_API_KEY", "personal-anthropic")
	t.Setenv("OPENROUTER_API_KEY", "personal-openrouter")
	t.Setenv("SALIX_TEST_ENV", "preserved")
	environment := strings.Join(runtimeAuthPiManagedExecEnv(map[string]any{"PATH": "/managed/bin"}, "/managed/pi", "managed-key"), "\n")
	for _, forbidden := range []string{"OPENAI_API_KEY=", "ANTHROPIC_API_KEY=", "OPENROUTER_API_KEY="} {
		if strings.Contains(environment, forbidden) {
			t.Fatalf("managed Pi environment retained %q", forbidden)
		}
	}
	for _, want := range []string{"PATH=/managed/bin", "SALIX_TEST_ENV=preserved", "PI_CODING_AGENT_DIR=/managed/pi", managedRuntimeAPIKeyEnv + "=managed-key"} {
		if !strings.Contains(environment, want) {
			t.Fatalf("managed Pi environment omitted %q", want)
		}
	}
}

func TestManagedPiAuthPlaceholderFailsClosed(t *testing.T) {
	for name, content := range map[string][]byte{
		"empty file":     nil,
		"malformed JSON": []byte("{"),
		"JSON null":      []byte("null"),
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "auth.json")
			if err := os.WriteFile(path, content, 0o600); err != nil {
				t.Fatal(err)
			}
			if !managedPiNativeAuthConflict(path) {
				t.Fatal("invalid Pi auth placeholder did not fail closed")
			}
		})
	}
}

func TestManagedRuntimeNativeProcessesUseOnlySelectedProviderCredential(t *testing.T) {
	for _, test := range []struct {
		provider, protocol, scheme, path, header string
	}{
		{"pi", "openai_completions", "bearer", "/v1/chat/completions", "Authorization"},
		{"pi", "anthropic_messages", "api_key", "/v1/messages", "x-api-key"},
		{"claude", "anthropic_messages", "bearer", "/v1/messages", "Authorization"},
		{"claude", "anthropic_messages", "api_key", "/v1/messages", "x-api-key"},
	} {
		t.Run(test.provider+"/"+test.protocol+"/"+test.scheme, func(t *testing.T) {
			t.Setenv("SALIX_TEST_MANAGED_PROVIDER_E2E", "1")
			t.Setenv("PI_CODING_AGENT_DIR", "")
			t.Setenv("ANTHROPIC_API_KEY", "personal-api-key")
			t.Setenv("ANTHROPIC_AUTH_TOKEN", "personal-auth-token")
			t.Setenv("ANTHROPIC_BASE_URL", "https://personal.example")
			requestSeen := make(chan struct{}, 1)
			server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				body, _ := io.ReadAll(request.Body)
				if request.URL.Path != test.path || !strings.Contains(string(body), `"model":"managed-model"`) {
					t.Errorf("provider request = %s %s", request.URL.Path, body)
				}
				want := "managed-secret"
				if test.header == "Authorization" {
					want = "Bearer " + want
				}
				if request.Header.Get(test.header) != want {
					t.Errorf("%s = %q, want %q", test.header, request.Header.Get(test.header), want)
				}
				select {
				case requestSeen <- struct{}{}:
				default:
				}
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write([]byte(`{"id":"synthetic"}`))
			}))
			defer server.Close()

			root := t.TempDir()
			c, err := newConnector(config{name: "managed-native", root: root, systemInfoInterval: 0})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			var command string
			if test.provider == "pi" {
				command = fakePortableRuntimeCommand(t, "pi")
			} else {
				command = fakeClaudeRuntimeCommand(t)
			}
			target := runtimeProbeTarget{provider: test.provider, identityMaterial: command}
			m := c.runtimeAuthCoordinator()
			endpoint := server.URL
			if test.provider == "pi" && strings.HasPrefix(test.protocol, "openai_") {
				endpoint += "/v1"
			}
			m.mu.Lock()
			m.managedCredentials[target.key()] = &managedRuntimeCredential{
				accountID: "account", accountVersion: "v1", endpoint: endpoint,
				protocol: test.protocol, authScheme: test.scheme, apiKey: "managed-secret", revision: 1,
			}
			m.subscriptionRevisions[target.key()] = 1
			m.mu.Unlock()
			input := externalRuntimeInput{
				sessionID: "managed-session", dispatchID: "dispatch", executionID: "execution", token: "token", command: command,
				workspace: t.TempDir(), model: "managed-model", payload: map[string]any{}, messages: []map[string]any{{"role": "user", "content": "hello"}},
			}
			implementation := c.runtimeImplementations[test.provider]
			if _, _, err := implementation.Send(context.Background(), input); err != nil {
				t.Fatal(err)
			}
			select {
			case <-requestSeen:
			case <-time.After(5 * time.Second):
				t.Fatal("native process did not call the selected synthetic provider")
			}
			if test.provider == "pi" {
				projection := filepath.Join(root, "external-runtime", "managed-pi", input.sessionID, "models.json")
				raw, err := os.ReadFile(projection)
				if err != nil {
					t.Fatal(err)
				}
				if strings.Contains(string(raw), "managed-secret") || !strings.Contains(string(raw), "$"+managedRuntimeAPIKeyEnv) {
					t.Fatalf("pi projection contains a secret or lacks the fixed env reference: %s", raw)
				}
				var decoded map[string]any
				if json.Unmarshal(raw, &decoded) != nil {
					t.Fatal("pi projection is not valid JSON")
				}
			}
		})
	}
}

func TestManagedRuntimeRevocationClosesAdmissionBeforeProcessExit(t *testing.T) {
	c, err := newConnector(config{name: "managed-revoke", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "pi", identityMaterial: "pi-command"}
	m := c.runtimeAuthCoordinator()
	m.mu.Lock()
	m.managedCredentials[target.key()] = &managedRuntimeCredential{accountID: "account", revision: 1}
	m.subscriptionRevisions[target.key()] = 1
	m.mu.Unlock()
	pi := c.runtimeImplementations["pi"].(*piRuntimeImplementation)
	pi.mu.Lock()
	blocked := pi.authGeneration
	blocked.wait.Add(1)
	pi.mu.Unlock()
	m.nativeCancelTimeout = 20 * time.Millisecond
	unlock := m.lockTarget(target.key())
	err = m.revokeManagedCredential(context.Background(), target, "account", 2)
	closed := m.managedCredential(target) == nil
	unlock()
	blocked.wait.Done()
	if err == nil || !closed {
		t.Fatalf("timed out revoke = %v, admission closed = %v", err, closed)
	}
	unlock = m.lockTarget(target.key())
	err = m.revokeManagedCredential(context.Background(), target, "account", 1)
	unlock()
	if err == nil {
		t.Fatal("late revoke bypassed the delivery fence")
	}
}

func TestManagedRuntimeComputeSyncRestoresAndRevokesStaticCredential(t *testing.T) {
	for _, provider := range []string{"pi", "claude"} {
		t.Run(provider, func(t *testing.T) {
			t.Setenv("PI_CODING_AGENT_DIR", "")
			t.Setenv("ANTHROPIC_API_KEY", "")
			t.Setenv("ANTHROPIC_AUTH_TOKEN", "")
			t.Setenv("CLAUDE_CODE_OAUTH_TOKEN", "")
			c, err := newConnector(config{name: "managed-sync", root: t.TempDir(), systemInfoInterval: 0})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			command := fakePortableRuntimeCommand(t, "pi")
			if provider == "claude" {
				command = fakeClaudeRuntimeCommand(t)
			}
			configureSubscriptionCompute(c)
			c.cfg.computeRuntimeProvider = provider
			c.runtimeInventory.mu.Lock()
			unmanagedIssue := map[string]string{"pi": "verification_required", "claude": "authentication_required"}[provider]
			c.runtimeInventory.runtimes = map[string]map[string]any{
				runtimeProbeTarget{provider: provider, identityMaterial: command}.key(): {
					"kind": "external", "provider": provider, "identity_material": command,
				},
			}
			c.runtimeInventory.run = func(target runtimeProbeTarget) map[string]any {
				return map[string]any{
					"kind": "external", "provider": target.provider, "identity_material": target.identityMaterial,
					"auth": map[string]any{
						"schema_version": 1, "status": "unauthenticated", "requires_openai_auth": false, "observed_at": int64(1),
					},
					"version_detected": true, "auth_ready": false, "native_server_startable": true,
					"app_server_startable": true, "ready": false, "readiness_issue": unmanagedIssue,
				}
			}
			c.runtimeInventory.mu.Unlock()
			var revision int64
			revoked := false
			off := activateRuntimeTransportForTest(c, func(request message) error {
				if request.Method != "runtime_subscription_access" {
					return nil
				}
				revision++
				access := managedDelivery("account", "https://models.example", "anthropic_messages", "bearer", "managed-secret", "v1", revision)
				if revoked {
					access = map[string]any{"revoked": true, "subscription_account_id": "account", "delivery_revision": revision}
				}
				c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: sealComputeSubscriptionTest(t, c, request, access)})
				return nil
			})
			defer off()
			targetMap := map[string]any{
				"tenant_id": "tenant", "project_id": "project", "workload_id": "workload",
				"runtime_instance_id": "runtime", "generation": 1, "connection_epoch": "epoch", "provider": provider,
			}
			session := computeRuntimeSession{instance: "runtime", epoch: "epoch", generation: 1, kind: "external_worker"}
			request := message{ID: "sync", Method: "runtime_subscription_sync", Params: map[string]any{"target": targetMap}}
			if reply := c.computeRuntimeAuthReply(context.Background(), request, session); reply.Type != "response" {
				t.Fatalf("static sync failed: %+v", reply)
			}
			target := runtimeProbeTarget{provider: provider, identityMaterial: command}
			installed := c.runtimeAuthCoordinator().managedCredential(target)
			if installed == nil || installed.apiKey != "managed-secret" {
				t.Fatal("static credential was not restored from the server binding")
			}
			read := message{ID: "read", Method: "runtime_auth_read", Params: map[string]any{"target": targetMap}}
			readReply := c.computeRuntimeAuthReply(context.Background(), read, session)
			readResult := mapParam(map[string]any{"result": readReply.Result}, "result")
			if readReply.Type != "response" || stringParam(mapParam(readResult, "auth"), "status") != "authenticated" || readResult["native_ready"] != true || readResult["ready"] != true {
				t.Fatalf("managed credential was not projected as ready: %+v", readReply)
			}
			c.runtimeInventory.workspaceReadiness = func() error { return errors.New("workspace unavailable") }
			read.ID = "read-workspace-unavailable"
			readReply = c.computeRuntimeAuthReply(context.Background(), read, session)
			readResult = mapParam(map[string]any{"result": readReply.Result}, "result")
			if readReply.Type != "response" || stringParam(mapParam(readResult, "auth"), "status") != "authenticated" || readResult["native_ready"] != true || readResult["ready"] != false {
				t.Fatalf("managed credential bypassed workspace readiness: %+v", readReply)
			}
			c.runtimeInventory.workspaceReadiness = nil
			generation := installed
			request.ID = "repeat"
			if reply := c.computeRuntimeAuthReply(context.Background(), request, session); reply.Type != "response" {
				t.Fatalf("repeat sync failed: %+v", reply)
			}
			if current := c.runtimeAuthCoordinator().managedCredential(target); current == generation || !current.sameConfiguration(generation) {
				t.Fatal("repeat sync changed behavior or failed to refresh the delivery snapshot")
			}
			leave, err := c.enterRuntimeAuthNativeCallAdmitted(context.Background(), provider, command)
			if err != nil {
				t.Fatalf("new work did not confirm the current binding: %v", err)
			}
			leave()
			revoked = true
			if leave, err = c.enterRuntimeAuthNativeCallAdmitted(context.Background(), provider, command); err == nil {
				leave()
				t.Fatal("new work was admitted after authoritative revocation")
			}
			if c.runtimeAuthCoordinator().managedCredential(target) != nil {
				t.Fatal("work admission did not close the revoked credential")
			}
			request.ID = "revoke"
			if reply := c.computeRuntimeAuthReply(context.Background(), request, session); reply.Type != "response" || mapParam(map[string]any{"result": reply.Result}, "result")["revoked"] != true {
				t.Fatalf("revocation was not acknowledged: %+v", reply)
			}
			if c.runtimeAuthCoordinator().managedCredential(target) != nil {
				t.Fatal("revoked credential remained admitted")
			}
			read.ID = "read-revoked"
			readReply = c.computeRuntimeAuthReply(context.Background(), read, session)
			readResult = mapParam(map[string]any{"result": readReply.Result}, "result")
			if readReply.Type != "response" || stringParam(mapParam(readResult, "auth"), "status") != "unauthenticated" || readResult["ready"] != false {
				t.Fatalf("revoked credential remained ready: %+v", readReply)
			}
		})
	}
}

func TestManagedClaudeOAuthRefreshPreservesBusyGeneration(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, key := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
		t.Setenv(key, "")
	}
	c, err := newConnector(config{name: "claude-oauth", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "claude", identityMaterial: fakePortableRuntimeCommand(t, "claude")}
	owner := c.runtimeAuthCoordinator()
	delivery := map[string]any{"credential_kind": "subscription_oauth", "subscription_account_id": "oauth-account", "account_version": "v1", "delivery_revision": int64(1), "access_token": "test-oauth-1", "expires_at": time.Now().Add(time.Hour).Unix()}
	apply := func() error {
		unlock := owner.lockTarget(target.key())
		defer unlock()
		return owner.applyManagedDeliveryLocked(context.Background(), target, delivery)
	}
	if err := apply(); err != nil {
		t.Fatal(err)
	}
	environment := runtimeAuthClaudeManagedExecEnv(nil, owner.managedCredential(target))
	if !strings.Contains(strings.Join(environment, "\n"), "CLAUDE_CODE_OAUTH_TOKEN=test-oauth-1") {
		t.Fatal("OAuth token was not provided to Claude")
	}
	leave := owner.enterNativeCall(target)
	delivery["access_token"], delivery["account_version"], delivery["delivery_revision"] = "test-oauth-2", "v2", int64(2)
	generation := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation).authGeneration
	if err := apply(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-generation.stop:
		t.Fatal("refresh interrupted native work")
	default:
	}
	leave()
	if owner.managedCredential(target).apiKey != "test-oauth-2" {
		t.Fatal("idle refresh did not install new access")
	}
	delivery["subscription_account_id"], delivery["delivery_revision"] = "other-account", int64(3)
	if err := apply(); err == nil {
		t.Fatal("refresh silently switched account")
	}
}
