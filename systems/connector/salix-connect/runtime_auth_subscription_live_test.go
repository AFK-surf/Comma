package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Opt-in smoke with an existing access token. Never copy or refresh the user's
// refresh token, write their auth file, or use their native CODEX_HOME.
func TestSubscriptionLiveCodex(t *testing.T) {
	authPath, binary := os.Getenv("SALIX_SUBSCRIPTION_LIVE_AUTH"), os.Getenv("SALIX_SUBSCRIPTION_LIVE_CODEX")
	if authPath == "" || binary == "" {
		t.Skip("requires explicit live credential and executable paths")
	}
	raw, err := os.ReadFile(authPath)
	if err != nil {
		t.Fatal("cannot read opted-in credentials")
	}
	var auth struct {
		Tokens struct {
			Access  string `json:"access_token"`
			Account string `json:"account_id"`
		} `json:"tokens"`
	}
	if json.Unmarshal(raw, &auth) != nil || auth.Tokens.Access == "" || auth.Tokens.Account == "" {
		t.Fatal("missing access projection")
	}
	parts := strings.Split(auth.Tokens.Access, ".")
	if len(parts) != 3 {
		t.Fatal("access token expiry unavailable")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	var claims struct {
		Expires int64 `json:"exp"`
	}
	if err != nil || json.Unmarshal(payload, &claims) != nil || claims.Expires <= time.Now().Unix()+90 {
		t.Fatal("access token requires user renewal")
	}
	nativeHome := t.TempDir()
	t.Setenv("HOME", nativeHome)
	t.Setenv("CODEX_HOME", filepath.Join(nativeHome, ".codex"))
	if err := os.MkdirAll(filepath.Join(nativeHome, ".codex"), 0700); err != nil {
		t.Fatal("cannot create isolated native home")
	}
	binDir := t.TempDir()
	command := filepath.Join(binDir, "codex")
	if os.Symlink(binary, command) != nil {
		t.Fatal("cannot prepare isolated executable")
	}
	t.Setenv("PATH", binDir+":/usr/bin:/bin:/usr/sbin:/sbin")
	c, err := newConnector(config{name: "subscription-live", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal("cannot create isolated connector")
	}
	defer c.closeExternalRuntimes()
	var revision atomic.Int64
	var credentialRevision atomic.Int64
	credentialRevision.Store(1)
	off := c.activateRuntimeTransport(func(_ context.Context, request message) error {
		if request.Method == "runtime_subscription_access" {
			// A native 401 is surfaced, never used to refresh the user's account.
			if stringParam(request.Params, "rejected_revision") != "" {
				c.completeRuntimeProxy(message{ID: request.ID, Type: "error", Error: "live refresh disabled"})
				return nil
			}
			c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{
				"bound": true, "credential_kind": "subscription_oauth", "subscription_account_id": "live-access-projection", "chatgpt_account_id": auth.Tokens.Account,
				"access_token": auth.Tokens.Access, "expires_at": claims.Expires, "credential_revision": "live-" + strconv.FormatInt(credentialRevision.Load(), 10), "delivery_revision": revision.Add(1),
			}})
		}
		return nil
	})
	defer off()
	for attempt := 0; attempt < 2; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		native, err := c.runtimeAuthCoordinator().codex.ensureTargetRuntime(ctx, runtimeProbeTarget{provider: "codex", identityMaterial: command})
		if err != nil {
			cancel()
			t.Fatalf("native process bootstrap failed before credential delivery: %v", err)
		}
		if native.ensureTaskInitialized(ctx) != nil {
			cancel()
			t.Fatal("access projection was not accepted")
		}
		thread, err := native.rpc(ctx, "thread/start", map[string]any{"model": "gpt-5.6-luna", "cwd": c.cfg.root, "ephemeral": false, "approvalPolicy": "never", "sandbox": "read-only"}, 15*time.Second)
		if err != nil {
			cancel()
			t.Fatal("native thread unavailable")
		}
		threadID := stringParam(mapParam(thread, "thread"), "id")
		startedTurn, err := native.rpc(ctx, "turn/start", map[string]any{"threadId": threadID, "input": []any{map[string]any{"type": "text", "text": "Reply exactly SUBSCRIPTION_RESTART_OK. Do not use tools."}}}, 15*time.Second)
		if err != nil {
			cancel()
			t.Fatal("native inference failed to start")
		}
		if attempt == 0 {
			if stringParam(mapParam(startedTurn, "turn"), "status") != "inProgress" {
				cancel()
				t.Fatal("live turn was not active for rotation check")
			}
			credentialRevision.Add(1)
			if native.ensureSubscription(ctx) != nil {
				cancel()
				t.Fatal("same-account update failed during live inference")
			}
		}
		completed := false
		for ctx.Err() == nil {
			result, readErr := native.rpc(ctx, "thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, 5*time.Second)
			if readErr == nil {
				turns, _ := mapParam(result, "thread")["turns"].([]any)
				if len(turns) > 0 {
					turn, _ := turns[len(turns)-1].(map[string]any)
					if turn["status"] == "failed" {
						cancel()
						t.Fatal("upstream rejected the live inference turn")
					}
					items, _ := turn["items"].([]any)
					for _, item := range items {
						value, _ := item.(map[string]any)
						if turn["status"] == "completed" && value["type"] == "agentMessage" && strings.TrimSpace(stringParam(value, "text")) == "SUBSCRIPTION_RESTART_OK" {
							completed = true
						}
					}
				}
				if completed {
					break
				}
			}
			time.Sleep(250 * time.Millisecond)
		}
		cancel()
		if !completed {
			t.Fatal("native inference did not complete with the expected response")
		}
		c.runtimeAuthCoordinator().codex.retireUnusableRuntimeGeneration(native)
	}
	if _, err = os.Stat(filepath.Join(nativeHome, ".codex", "auth.json")); !os.IsNotExist(err) {
		t.Fatal("native access auth was persisted")
	}
	after, err := os.ReadFile(authPath)
	if err != nil || string(after) != string(raw) {
		t.Fatal("source credential file changed during smoke test")
	}
}

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
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: binary}
	manager := c.runtimeAuthCoordinator()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
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
