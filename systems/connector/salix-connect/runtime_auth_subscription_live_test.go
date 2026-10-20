package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// This smoke uses synthetic tokens and an isolated home. It makes no model request.
func TestSubscriptionLocalCodexPreservesNativeLogin(t *testing.T) {
	binary := os.Getenv("SALIX_SUBSCRIPTION_CODEX_BINARY")
	if binary == "" {
		t.Skip("set SALIX_SUBSCRIPTION_CODEX_BINARY to an installed Codex binary")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", home)
	for _, key := range []string{"OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"} {
		t.Setenv(key, "")
	}
	token := func(account string) string {
		claims, _ := json.Marshal(map[string]any{
			"email": account + "@example.test", "exp": int64(4102444800),
			"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": account, "chatgpt_plan_type": "plus"},
		})
		return "eyJhbGciOiJub25lIn0." + base64.RawURLEncoding.EncodeToString(claims) + ".synthetic"
	}
	original, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "last_refresh": time.Now().UTC().Format(time.RFC3339), "tokens": map[string]any{
		"access_token": token("personal"), "id_token": token("personal"), "refresh_token": "synthetic-refresh", "account_id": "personal",
	}})
	authPath := filepath.Join(home, "auth.json")
	if err := os.WriteFile(authPath, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte("cli_auth_credentials_store = \"file\"\ncheck_for_update_on_startup = false\n"), 0600); err != nil {
		t.Fatal(err)
	}
	c, err := newConnector(config{name: "native-credential-switch", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: binary}
	manager := c.runtimeAuthCoordinator()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	native, err := manager.codex.ensureTargetRuntime(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	if err := native.ensureInitialized(ctx); err != nil {
		t.Fatal(err)
	}
	checkAccount := func(runtime *codexRuntime, expected string) {
		t.Helper()
		result, err := runtime.rpc(ctx, "account/read", map[string]any{"refreshToken": false}, 5*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if stringParam(mapParam(result, "account"), "email") != expected+"@example.test" {
			t.Fatalf("unexpected account: %v", result)
		}
	}
	checkAccount(native, "personal")
	for index, account := range []string{"organization-a", "organization-b"} {
		params := map[string]any{"subscription_account_id": account, "chatgpt_account_id": account,
			"access_token": token(account), "expires_at": int64(4102444800), "credential_revision": account, "delivery_revision": int64(index + 1)}
		if err := native.applySubscription(ctx, params, func() bool { return true }, false); err != nil {
			t.Fatal(err)
		}
		checkAccount(native, account)
		if !native.isRunning() {
			t.Fatal("binding stopped the app-server")
		}
		persisted, err := os.ReadFile(authPath)
		if err != nil || string(persisted) != string(original) {
			t.Fatal("persistent personal login changed")
		}
	}
	manager.revokeSubscription(target, "organization-b", 3)
	select {
	case <-native.exited:
	case <-ctx.Done():
		t.Fatal("revoked app-server did not exit")
	}
	restored, err := manager.codex.ensureTargetRuntime(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	if err := restored.ensureInitialized(ctx); err != nil {
		t.Fatal(err)
	}
	checkAccount(restored, "personal")
	persisted, err := os.ReadFile(authPath)
	if err != nil || string(persisted) != string(original) {
		t.Fatal("unbind changed persistent personal login")
	}
}
