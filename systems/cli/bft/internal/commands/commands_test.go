package commands

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/config"
	"github.com/AFK-surf/comma/systems/cli/bft/internal/output"
)

func TestAuthLoginStartsDeviceLoginPollsAndPersistsConfig(t *testing.T) {
	var sawStart bool
	var sawPoll bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/cli/auth/device":
			if r.Header.Get("Authorization") != "" {
				t.Fatalf("device start should not send bearer token")
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode start body: %v", err)
			}
			if body["client_name"] != "agent laptop" {
				t.Fatalf("client_name = %#v", body["client_name"])
			}
			sawStart = true
			writeOK(w, map[string]any{
				"device_code":               "device-secret",
				"user_code":                 "ABCD1234",
				"verification_uri":          serverURL(r) + "/cli/device-login",
				"verification_uri_complete": serverURL(r) + "/cli/device-login/ABCD1234",
				"expires_at":                futureAuthExpiresAt(),
				"interval_seconds":          1,
			})
		case "/v1/cli/auth/device/poll":
			if r.Header.Get("Authorization") != "" {
				t.Fatalf("device poll should not send bearer token")
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode poll body: %v", err)
			}
			if body["device_code"] != "device-secret" {
				t.Fatalf("device_code = %#v", body["device_code"])
			}
			sawPoll = true
			writeOK(w, map[string]any{
				"status":       "approved",
				"token":        "device-cli-token",
				"token_type":   "bearer",
				"expires_at":   "2026-06-24T00:00:00Z",
				"granted_orgs": []map[string]any{{"id": "org_1", "slug": "acme", "name": "Acme"}},
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	exitCode, stdout, stderr := runCLI(t, []string{
		"auth", "login",
		"--url", server.URL,
		"--config", configPath,
		"--client-name", "agent laptop",
		"--json",
	}, nil)

	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if stderr != "" {
		t.Fatalf("stderr = %q, want empty", stderr)
	}
	if !sawStart || !sawPoll {
		t.Fatalf("saw start=%v poll=%v", sawStart, sawPoll)
	}
	if strings.Contains(stdout, "device-cli-token") {
		t.Fatal("raw CLI token leaked in output")
	}

	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["user_code"] != "ABCD1234" ||
		data["verification_uri"] != server.URL+"/cli/device-login" ||
		data["verification_uri_complete"] != server.URL+"/cli/device-login/ABCD1234" {
		t.Fatalf("data = %#v", data)
	}

	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load persisted config: %v", err)
	}
	if cfg.APIBaseURL != server.URL || cfg.Token != "device-cli-token" {
		t.Fatalf("persisted config = %#v", cfg)
	}
	if len(cfg.GrantedOrgs) != 1 || cfg.GrantedOrgs[0].Slug != "acme" {
		t.Fatalf("persisted granted orgs = %#v", cfg.GrantedOrgs)
	}
}

func TestAuthDeviceLoginTextOutputShowsApprovalURLBeforeSavedResult(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/cli/auth/device":
			writeOK(w, map[string]any{
				"device_code":               "device-secret",
				"user_code":                 "ABCD1234",
				"verification_uri":          serverURL(r) + "/cli/device-login",
				"verification_uri_complete": serverURL(r) + "/cli/device-login/ABCD1234",
				"expires_at":                futureAuthExpiresAt(),
				"interval_seconds":          1,
			})
		case "/v1/cli/auth/device/poll":
			writeOK(w, map[string]any{
				"status":       "approved",
				"token":        "device-cli-token",
				"token_type":   "bearer",
				"expires_at":   "2026-06-24T00:00:00Z",
				"granted_orgs": []map[string]any{{"id": "org_1", "slug": "acme", "name": "Acme"}},
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	exitCode, stdout, stderr := runCLI(t, []string{
		"auth", "login",
		"--url", server.URL,
		"--config", configPath,
		"--output", "text",
	}, nil)

	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "/cli/device-login/ABCD1234") ||
		!strings.Contains(stdout, "User code: ABCD1234") ||
		!strings.Contains(stdout, "Waiting for approval") ||
		!strings.Contains(stdout, "BFT CLI login saved") {
		t.Fatalf("stdout = %q", stdout)
	}
	if strings.Contains(stdout, "device-cli-token") || strings.Contains(stderr, "device-cli-token") {
		t.Fatal("raw CLI token leaked in output")
	}
}

func TestAuthDeviceLoginTerminalStatusDoesNotPersistConfig(t *testing.T) {
	for _, test := range []struct {
		status string
		code   string
	}{
		{"cancelled", "cli_device_login_cancelled"},
		{"expired", "cli_device_login_expired"},
	} {
		t.Run(test.status, func(t *testing.T) {
			server := httptest.NewServer(deviceLoginTerminalStatusHandler(t, test.status))
			defer server.Close()

			configPath := filepath.Join(t.TempDir(), "cli.json")
			exitCode, stdout, stderr := runCLI(t, []string{
				"auth", "login",
				"--url", server.URL,
				"--config", configPath,
				"--json",
			}, nil)

			if exitCode != output.ExitUsage {
				t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
			}
			if stdout != "" {
				t.Fatalf("stdout = %q, want empty", stdout)
			}
			var body map[string]any
			decodeJSON(t, stderr, &body)
			if body["error"].(map[string]any)["code"] != test.code {
				t.Fatalf("stderr body = %#v", body)
			}
			assertNoPersistedToken(t, configPath)
		})
	}
}

func TestAuthDeviceLoginStopsPollingAtServerExpiry(t *testing.T) {
	var pollCount int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/cli/auth/device":
			writeOK(w, map[string]any{
				"device_code":               "device-secret",
				"user_code":                 "ABCD1234",
				"verification_uri":          serverURL(r) + "/cli/device-login",
				"verification_uri_complete": serverURL(r) + "/cli/device-login/ABCD1234",
				"expires_at":                time.Now().Add(25 * time.Millisecond).UTC().Format(time.RFC3339Nano),
				"interval_seconds":          60,
			})
		case "/v1/cli/auth/device/poll":
			pollCount++
			writeOK(w, map[string]any{
				"status":           "pending",
				"user_code":        "ABCD1234",
				"interval_seconds": 60,
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	exitCode, stdout, stderr := runCLI(t, []string{
		"auth", "login",
		"--url", server.URL,
		"--config", configPath,
		"--json",
	}, nil)

	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want empty", stdout)
	}
	if pollCount != 1 {
		t.Fatalf("poll count = %d, want exactly one pending poll before local expiry", pollCount)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	if body["error"].(map[string]any)["code"] != "cli_device_login_expired" {
		t.Fatalf("stderr body = %#v", body)
	}
	assertNoPersistedToken(t, configPath)
}

func TestDeviceLoginDeadlineFallsBackAndCapsServerExpiry(t *testing.T) {
	startedAt := time.Date(2026, 6, 24, 9, 0, 0, 0, time.UTC)
	fallback := startedAt.Add(maxDeviceLoginWait)

	if got := deviceLoginDeadline(startedAt, ""); !got.Equal(fallback) {
		t.Fatalf("missing expires_at deadline = %s, want fallback %s", got, fallback)
	}

	if got := deviceLoginDeadline(startedAt, "3026-06-24T09:00:00Z"); !got.Equal(fallback) {
		t.Fatalf("far future expires_at deadline = %s, want fallback %s", got, fallback)
	}

	serverDeadline := startedAt.Add(2 * time.Minute)
	if got := deviceLoginDeadline(startedAt, serverDeadline.Format(time.RFC3339Nano)); !got.Equal(serverDeadline) {
		t.Fatalf("server expires_at deadline = %s, want %s", got, serverDeadline)
	}
}

func TestAuthStatusReportsConfiguredSessionWithoutPrintingToken(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{
		APIBaseURL:  "https://teams.example.test",
		Token:       "from-config-token",
		ExpiresAt:   "2026-06-24T00:00:00Z",
		GrantedOrgs: []config.OrgRef{{ID: "org_1", Slug: "acme", Name: "Acme"}},
	}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"auth", "status",
		"--config", configPath,
		"--json",
	}, nil)

	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if strings.Contains(stdout, "from-config-token") || strings.Contains(stderr, "from-config-token") {
		t.Fatal("raw CLI token leaked in auth status output")
	}

	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "auth_status" ||
		data["api_base_url"] != "https://teams.example.test" ||
		data["expires_at"] != "2026-06-24T00:00:00Z" ||
		data["token_configured"] != true {
		t.Fatalf("data = %#v", data)
	}
	grantedOrgs := data["granted_orgs"].([]any)
	if len(grantedOrgs) != 1 || grantedOrgs[0].(map[string]any)["slug"] != "acme" {
		t.Fatalf("granted_orgs = %#v", data["granted_orgs"])
	}
}

func TestAuthOrgsAddStartsDeviceApprovalWithCurrentTokenAndPersistsGrants(t *testing.T) {
	var sawStart bool
	var sawPoll bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/cli/auth/orgs/device":
			sawStart = true
			if r.Header.Get("Authorization") != "Bearer from-config-token" {
				t.Fatalf("org grant start Authorization = %q", r.Header.Get("Authorization"))
			}
			writeOK(w, map[string]any{
				"device_code":               "org-grant-device-secret",
				"user_code":                 "ORG12345",
				"verification_uri":          serverURL(r) + "/cli/device-login",
				"verification_uri_complete": serverURL(r) + "/cli/device-login/ORG12345",
				"expires_at":                futureAuthExpiresAt(),
				"interval_seconds":          1,
			})
		case "/v1/cli/auth/orgs/device/poll":
			sawPoll = true
			if r.Header.Get("Authorization") != "Bearer from-config-token" {
				t.Fatalf("org grant poll Authorization = %q", r.Header.Get("Authorization"))
			}
			writeOK(w, map[string]any{
				"mode":         "auth_org_grant_poll",
				"status":       "approved",
				"granted_orgs": []map[string]any{{"id": "org_1", "slug": "acme", "name": "Acme"}, {"id": "org_2", "slug": "beta", "name": "Beta"}},
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token", ExpiresAt: "2026-06-24T00:00:00Z"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"auth", "orgs", "add", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !sawStart || !sawPoll {
		t.Fatalf("saw start=%v poll=%v", sawStart, sawPoll)
	}
	if strings.Contains(stdout, "from-config-token") || strings.Contains(stderr, "from-config-token") {
		t.Fatal("raw CLI token leaked in auth orgs add output")
	}

	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load persisted config: %v", err)
	}
	if len(cfg.GrantedOrgs) != 2 || cfg.GrantedOrgs[1].Slug != "beta" {
		t.Fatalf("persisted granted orgs = %#v", cfg.GrantedOrgs)
	}
}

func TestAuthOrgsRevokeRevokesOneOrgAndUpdatesLocalGrants(t *testing.T) {
	var sawRevoke bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/auth/orgs/revoke" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("Authorization = %q", r.Header.Get("Authorization"))
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode revoke body: %v", err)
		}
		if body["org"] != "beta" {
			t.Fatalf("org = %#v", body["org"])
		}
		sawRevoke = true
		writeOK(w, map[string]any{
			"mode":         "auth_org_revoke",
			"revoked":      true,
			"org":          map[string]any{"id": "org_2", "slug": "beta", "name": "Beta"},
			"granted_orgs": []map[string]any{{"id": "org_1", "slug": "acme", "name": "Acme"}},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{
		APIBaseURL:  server.URL,
		Token:       "from-config-token",
		ExpiresAt:   "2026-06-24T00:00:00Z",
		GrantedOrgs: []config.OrgRef{{ID: "org_1", Slug: "acme", Name: "Acme"}, {ID: "org_2", Slug: "beta", Name: "Beta"}},
	}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"auth", "orgs", "revoke", "--org", "beta", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !sawRevoke {
		t.Fatal("server revoke was not called")
	}
	if strings.Contains(stdout, "from-config-token") || strings.Contains(stderr, "from-config-token") {
		t.Fatal("raw CLI token leaked in auth orgs revoke output")
	}

	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load persisted config: %v", err)
	}
	if len(cfg.GrantedOrgs) != 1 || cfg.GrantedOrgs[0].Slug != "acme" {
		t.Fatalf("persisted granted orgs = %#v", cfg.GrantedOrgs)
	}
}

func TestAuthLogoutRevokesServerSessionBeforeClearingConfig(t *testing.T) {
	var sawLogout bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/auth/logout" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("Authorization = %q", r.Header.Get("Authorization"))
		}
		sawLogout = true
		writeOK(w, map[string]any{"mode": "auth_logout", "revoked": true})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token", ExpiresAt: "2026-06-24T00:00:00Z"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"auth", "logout", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !sawLogout {
		t.Fatal("server logout was not called")
	}

	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Token != "" || cfg.ExpiresAt != "" {
		t.Fatalf("config token should be cleared: %#v", cfg)
	}

	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["server_revoked"] != true || data["token_configured"] != false {
		t.Fatalf("data = %#v", data)
	}
}

func TestAuthLogoutRevokesEnvAndConfigTokens(t *testing.T) {
	seenAuth := map[string]bool{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/auth/logout" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		seenAuth[r.Header.Get("Authorization")] = true
		writeOK(w, map[string]any{"mode": "auth_logout", "revoked": true})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token", ExpiresAt: "2026-06-24T00:00:00Z"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"auth", "logout", "--config", configPath, "--json"}, map[string]string{
		"BFT_CLI_TOKEN": "from-env-token",
	})
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !seenAuth["Bearer from-env-token"] || !seenAuth["Bearer from-config-token"] {
		t.Fatalf("seen auth headers = %#v", seenAuth)
	}

	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Token != "" || cfg.ExpiresAt != "" {
		t.Fatalf("config token should be cleared: %#v", cfg)
	}
}

func TestAuthLogoutWithoutTokenClearsLocalConfigOnly(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: "https://teams.example.test"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"auth", "logout", "--config", configPath, "--json"}, map[string]string{
		"BFT_CLI_TOKEN": "",
		"BFT_API_TOKEN": "",
	})
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}

	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["server_revoked"] != false || data["token_configured"] != false {
		t.Fatalf("data = %#v", data)
	}
}

func TestAuthLogoutKeepsConfigWhenServerRevokeFails(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/auth/logout" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		writeAPIError(w, http.StatusServiceUnavailable, "revoke_failed", "Could not revoke CLI session.")
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token", ExpiresAt: "2026-06-24T00:00:00Z"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"auth", "logout", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitUnavailable {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}

	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Token != "from-config-token" || cfg.ExpiresAt == "" {
		t.Fatalf("config should be preserved after failed revoke: %#v", cfg)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want empty", stdout)
	}
	if !strings.Contains(stderr, "revoke_failed") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestContextUsesStoredTokenAndJSONEnvelope(t *testing.T) {
	var authHeader string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader = r.Header.Get("Authorization")
		if r.URL.Path != "/v1/cli/context" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if r.URL.Query().Get("org") != "acme" || r.URL.Query().Get("project") != "support" {
			t.Fatalf("query = %s", r.URL.RawQuery)
		}
		writeOK(w, map[string]any{
			"context": map[string]any{
				"org":     map[string]any{"id": "org_1", "slug": "acme", "name": "Acme"},
				"project": map[string]any{"id": "proj_1", "slug": "support", "name": "Support"},
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"context", "--org", "acme", "--project", "support", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	if authHeader != "Bearer from-config-token" {
		t.Fatalf("Authorization = %q", authHeader)
	}

	var body map[string]any
	decodeJSON(t, stdout, &body)
	if body["schema_version"] != output.SchemaVersion || body["ok"] != true {
		t.Fatalf("body = %#v", body)
	}
}

func TestAgentLoginSmokeAndContextWorkflow(t *testing.T) {
	var sawAuthDeviceStart bool
	var sawAuthDevicePoll bool
	var sawOrgsSmoke bool
	var sawContext bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/cli/auth/device":
			sawAuthDeviceStart = true
			if r.Header.Get("Authorization") != "" {
				t.Fatalf("device start should not send bearer token")
			}
			writeOK(w, map[string]any{
				"device_code":               "workflow-device-secret",
				"user_code":                 "FLOW1234",
				"verification_uri":          serverURL(r) + "/cli/device-login",
				"verification_uri_complete": serverURL(r) + "/cli/device-login/FLOW1234",
				"expires_at":                futureAuthExpiresAt(),
				"interval_seconds":          1,
			})
		case "/v1/cli/auth/device/poll":
			sawAuthDevicePoll = true
			if r.Header.Get("Authorization") != "" {
				t.Fatalf("device poll should not send bearer token")
			}
			writeOK(w, map[string]any{
				"status":       "approved",
				"token":        "workflow-token",
				"token_type":   "bearer",
				"expires_at":   "2026-06-24T00:00:00Z",
				"granted_orgs": []map[string]any{{"id": "org_1", "slug": "acme", "name": "Acme"}},
			})
		case "/v1/cli/orgs":
			sawOrgsSmoke = true
			if r.Header.Get("Authorization") != "Bearer workflow-token" {
				t.Fatalf("orgs Authorization = %q", r.Header.Get("Authorization"))
			}
			writeOK(w, map[string]any{"orgs": []map[string]any{{"slug": "acme", "name": "Acme", "id": "org_1"}}})
		case "/v1/cli/context":
			sawContext = true
			if r.Header.Get("Authorization") != "Bearer workflow-token" {
				t.Fatalf("context Authorization = %q", r.Header.Get("Authorization"))
			}
			if r.URL.Query().Get("org") != "acme" || r.URL.Query().Get("project") != "support" {
				t.Fatalf("query = %s", r.URL.RawQuery)
			}
			writeOK(w, map[string]any{
				"context": map[string]any{
					"org":     map[string]any{"id": "org_1", "slug": "acme", "name": "Acme"},
					"project": map[string]any{"id": "proj_1", "slug": "support", "name": "Support"},
				},
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	loginExit, loginStdout, loginStderr := runCLI(t, []string{"auth", "login", "--url", server.URL, "--config", configPath, "--json"}, nil)
	if loginExit != output.ExitOK {
		t.Fatalf("login exit = %d stdout=%s stderr=%s", loginExit, loginStdout, loginStderr)
	}
	smokeExit, smokeStdout, smokeStderr := runCLI(t, []string{"onboarding", "smoke", "--step", "cli-login", "--config", configPath, "--json"}, nil)
	if smokeExit != output.ExitOK {
		t.Fatalf("smoke exit = %d stdout=%s stderr=%s", smokeExit, smokeStdout, smokeStderr)
	}
	var smokeBody map[string]any
	decodeJSON(t, smokeStdout, &smokeBody)
	if smokeBody["data"].(map[string]any)["status"] != "ok" {
		t.Fatalf("smoke body = %#v", smokeBody)
	}
	contextExit, contextStdout, contextStderr := runCLI(t, []string{"context", "--org", "acme", "--project", "support", "--config", configPath, "--json"}, nil)
	if contextExit != output.ExitOK {
		t.Fatalf("context exit = %d stdout=%s stderr=%s", contextExit, contextStdout, contextStderr)
	}
	var contextBody map[string]any
	decodeJSON(t, contextStdout, &contextBody)
	if contextBody["ok"] != true || !sawAuthDeviceStart || !sawAuthDevicePoll || !sawOrgsSmoke || !sawContext {
		t.Fatalf("workflow saw start=%v poll=%v orgs=%v context=%v body=%#v", sawAuthDeviceStart, sawAuthDevicePoll, sawOrgsSmoke, sawContext, contextBody)
	}
}

func TestCommandsSchemaIsMachineReadable(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"commands", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "commands" {
		t.Fatalf("data = %#v", data)
	}
	if len(data["commands"].([]any)) == 0 {
		t.Fatal("commands metadata is empty")
	}
	if !strings.Contains(stdout, "conversations trace") {
		t.Fatalf("commands metadata should include conversation read/debug commands: %s", stdout)
	}
	if !strings.Contains(stdout, "slack connects create") {
		t.Fatalf("commands metadata should include Slack connect management commands: %s", stdout)
	}
	if !strings.Contains(stdout, "meetings calendar status") {
		t.Fatalf("commands metadata should include bounded meeting calendar diagnostics: %s", stdout)
	}
	var runnerInstall map[string]any
	for _, raw := range data["commands"].([]any) {
		command := raw.(map[string]any)
		if command["name"] == "runners install-command" {
			runnerInstall = command
			break
		}
	}
	if runnerInstall == nil || runnerInstall["requires_confirm"] != true || !strings.Contains(runnerInstall["example"].(string), "--confirm-mutating") {
		t.Fatalf("runner install command must advertise its mutation gate: %#v", runnerInstall)
	}
}

func TestJSONFieldsProjectTopLevelData(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"commands", "--json", "--fields", "mode,commands"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "commands" {
		t.Fatalf("data = %#v", data)
	}
	if _, ok := data["commands"]; !ok {
		t.Fatalf("commands missing from data = %#v", data)
	}
	if _, ok := data["exit_codes"]; ok {
		t.Fatalf("exit_codes should have been projected out: %#v", data)
	}
}

func TestNonTTYStdoutDefaultsToJSONAndAllowsFields(t *testing.T) {
	stdoutPath := filepath.Join(t.TempDir(), "stdout.json")
	stdoutFile, err := os.Create(stdoutPath)
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer

	exitCode := Run([]string{"commands", "--fields", "mode"}, stdoutFile, &stderr, os.Getenv)
	if closeErr := stdoutFile.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr.String())
	}

	raw, err := os.ReadFile(stdoutPath)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	decodeJSON(t, string(raw), &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "commands" {
		t.Fatalf("data = %#v", data)
	}
	if _, ok := data["commands"]; ok {
		t.Fatalf("commands should have been projected out: %#v", data)
	}
}

func TestOutputTextOverridesNonTTYDefaultJSON(t *testing.T) {
	stdoutPath := filepath.Join(t.TempDir(), "stdout.txt")
	stdoutFile, err := os.Create(stdoutPath)
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer

	exitCode := Run([]string{"version", "--output", "text"}, stdoutFile, &stderr, os.Getenv)
	if closeErr := stdoutFile.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr.String())
	}

	raw, err := os.ReadFile(stdoutPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(raw); !strings.HasPrefix(got, "bft ") {
		t.Fatalf("stdout = %q", got)
	}
}

func TestEarlyParserErrorRespectsExplicitJSON(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"definitely-not-a-command", "--json"}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want empty", stdout)
	}
	if strings.Contains(stderr, "Did you mean") {
		t.Fatalf("stderr should not include fuzzy suggestions: %s", stderr)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	if body["ok"] != false {
		t.Fatalf("body = %#v", body)
	}
	errBody := body["error"].(map[string]any)
	if errBody["code"] != "unknown_command" {
		t.Fatalf("error = %#v", errBody)
	}
}

func TestEarlyParserErrorOutputTextOverridesNonTTYDefaultJSON(t *testing.T) {
	stdoutPath := filepath.Join(t.TempDir(), "stdout.txt")
	stdoutFile, err := os.Create(stdoutPath)
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer

	exitCode := Run([]string{"agent", "--output", "text"}, stdoutFile, &stderr, os.Getenv)
	if closeErr := stdoutFile.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr.String())
	}
	if strings.HasPrefix(strings.TrimSpace(stderr.String()), "{") {
		t.Fatalf("stderr should be text, got %s", stderr.String())
	}
	if !strings.Contains(stderr.String(), "Run bft agent help") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestInvalidOutputOptionsFailFast(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{"fields require JSON output", []string{"commands", "--fields", "mode"}, "Use --fields only with JSON output"},
		{"unsupported output format", []string{"commands", "--output", "xml"}, "Unsupported output format"},
	} {
		t.Run(test.name, func(t *testing.T) {
			exitCode, stdout, stderr := runCLI(t, test.args, nil)
			if exitCode != output.ExitUsage {
				t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
			}
			if !strings.Contains(stderr, test.want) {
				t.Fatalf("stderr = %q", stderr)
			}
		})
	}
}

func TestAgentHelpIsMachineReadable(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"agent", "help", "onboarding", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "agent_help" || data["topic"] != "onboarding" {
		t.Fatalf("data = %#v", data)
	}
	if len(data["commands"].([]any)) == 0 || data["next_action"] == "" {
		t.Fatalf("data = %#v", data)
	}
}

func TestRunnerAgentHelpRequiresMutationConfirmation(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"agent", "help", "runners", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	commands := data["commands"].([]any)
	want := "bft runners install-command --org <org> --confirm-mutating --json"
	found := false
	for _, command := range commands {
		found = found || command == want
	}
	if !found {
		t.Fatalf("runner agent help must preserve the explicit mutation gate: %#v", commands)
	}
	rules := data["rules"].([]any)
	wantRule := "After approval, generate exactly one install command and execute its returned command immediately without a second generation request."
	foundRule := false
	for _, rule := range rules {
		foundRule = foundRule || rule == wantRule
	}
	if !foundRule {
		t.Fatalf("runner agent help must prevent duplicate one-time codes: %#v", rules)
	}
}

func TestCompletionGeneratesShellScript(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"completion", "bash"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	if !strings.Contains(stdout, "complete -F _bft_completion bft") {
		t.Fatalf("stdout = %q", stdout)
	}
}

func TestCompletionHonorsJSONOutput(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"completion", "zsh", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "completion" || data["shell"] != "zsh" || !strings.Contains(data["script"].(string), "#compdef bft") {
		t.Fatalf("data = %#v", data)
	}
}

func TestVersionHonorsJSONOutput(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"version", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	if stderr != "" {
		t.Fatalf("stderr = %q, want empty", stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if body["schema_version"] != output.SchemaVersion || body["ok"] != true || data["version"] == "" {
		t.Fatalf("body = %#v", body)
	}
}

func TestVersionCheckReportsConfiguredRelease(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/release" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		writeOK(w, map[string]any{
			"mode":        "bft_cli_release",
			"release_id":  "bft-cli-20260624",
			"install_url": serverURL(r) + "/v1/cli/install.sh",
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"version", "--check", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["latest_version"] != "bft-cli-20260624" || data["update_state"] != "available" {
		t.Fatalf("data = %#v", data)
	}
}

func TestUpdatePrintsInstallerPlan(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/release" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		writeOK(w, map[string]any{
			"mode":        "bft_cli_release",
			"release_id":  "bft-cli-20260624",
			"install_url": serverURL(r) + "/v1/cli/install.sh",
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"update", "--config", configPath, "--install-dir", "/tmp/bft-bin", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["mode"] != "bft_update" || data["executed"] != false {
		t.Fatalf("data = %#v", data)
	}
	command := data["command"].(string)
	if !strings.Contains(command, "/v1/cli/install.sh") || !strings.Contains(command, "BFT_CLI_INSTALL_DIR='/tmp/bft-bin' sh") {
		t.Fatalf("command = %q", command)
	}
}

func TestUpdateExecuteRequiresConfirmation(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: "https://teams.example.test"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"update", "--execute", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "confirm_mutating_required") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestOrgsListSupportsLimitAndFilter(t *testing.T) {
	var rawQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rawQuery = r.URL.RawQuery
		if r.URL.Path != "/v1/cli/orgs" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		writeOK(w, map[string]any{
			"orgs": []map[string]any{
				{"slug": "acme-one", "name": "Acme One", "id": "org_1"},
				{"slug": "beta", "name": "Beta", "id": "org_2"},
				{"slug": "acme-two", "name": "Acme Two", "id": "org_3"},
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"orgs", "list", "--config", configPath, "--filter", "acme", "--limit", "1", "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	if !strings.Contains(rawQuery, "filter=acme") || !strings.Contains(rawQuery, "limit=1") {
		t.Fatalf("query = %q", rawQuery)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	orgs := data["orgs"].([]any)
	if len(orgs) != 1 {
		t.Fatalf("orgs = %#v", orgs)
	}
	meta := data["list"].(map[string]any)
	if meta["matched"].(float64) != 2 || meta["returned"].(float64) != 1 || meta["truncated"] != true {
		t.Fatalf("meta = %#v", meta)
	}
}

func TestInvalidListLimitFailsFast(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"orgs", "list", "--limit", "0", "--json"}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	errBody := body["error"].(map[string]any)
	if errBody["code"] != "invalid_limit" {
		t.Fatalf("error = %#v", errBody)
	}
}

func TestOnboardingCliLoginNeedsManualWithoutToken(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{
		"onboarding", "smoke",
		"--step", "cli-login",
		"--config", filepath.Join(t.TempDir(), "missing.json"),
		"--json",
	}, nil)
	if exitCode != output.ExitNeedsManual {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["status"] != "needs_manual" || data["step_id"] != "cli-login" {
		t.Fatalf("data = %#v", data)
	}
}

func TestOnboardingFeishuCliAssistEmitsManualGate(t *testing.T) {
	larkCLI := filepath.Join(t.TempDir(), "lark-cli")
	if err := os.WriteFile(larkCLI, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write lark cli: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"onboarding", "smoke",
		"--step", "feishu-cli",
		"--lark-cli", larkCLI,
		"--assist-lark-app-init",
		"--json",
	}, nil)
	if exitCode != output.ExitNeedsManual {
		t.Fatalf("exit = %d stderr=%s", exitCode, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["status"] != "needs_manual" {
		t.Fatalf("data = %#v", data)
	}
	gates := data["gates"].([]any)
	if len(gates) != 2 {
		t.Fatalf("gates = %#v", gates)
	}
	assistGate := gates[1].(map[string]any)
	if assistGate["gate_id"] != "lark-cli.config-init.new" || assistGate["status"] != "needs_manual" {
		t.Fatalf("assist gate = %#v", assistGate)
	}
}

func TestOnboardingFeishuChecksIgnoresOnlyExplicitlyOptionalSkippedGates(t *testing.T) {
	tests := []struct {
		name       string
		gates      []map[string]any
		wantExit   int
		wantStatus string
	}{
		{
			name: "optional calendar notification policy is visible but does not block",
			gates: []map[string]any{
				{"gate_id": "bot.chat_access", "status": "ok", "required": true},
				{
					"gate_id":      "bot.calendar",
					"status":       "skipped",
					"reason_class": "calendar_policy_not_configured",
					"required":     false,
				},
			},
			wantExit:   output.ExitOK,
			wantStatus: "ok",
		},
		{
			name: "a required skipped gate still blocks completion",
			gates: []map[string]any{
				{"gate_id": "bot.chat_access", "status": "skipped", "required": true},
			},
			wantExit:   output.ExitNeedsManual,
			wantStatus: "needs_manual",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/cli/feishu/checks" || r.Method != http.MethodPost {
					t.Fatalf("request = %s %s", r.Method, r.URL.Path)
				}
				writeOK(w, map[string]any{"checks": map[string]any{"gates": tt.gates}})
			}))
			defer server.Close()

			configPath := filepath.Join(t.TempDir(), "cli.json")
			if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
				t.Fatalf("persist config: %v", err)
			}

			exitCode, stdout, stderr := runCLI(t, []string{
				"onboarding", "smoke",
				"--step", "feishu-checks",
				"--org", "acme",
				"--project", "support",
				"--config", configPath,
				"--json",
			}, nil)
			if exitCode != tt.wantExit {
				t.Fatalf("exit = %d, want %d; stdout=%s stderr=%s", exitCode, tt.wantExit, stdout, stderr)
			}

			var body map[string]any
			decodeJSON(t, stdout, &body)
			data := body["data"].(map[string]any)
			if data["status"] != tt.wantStatus {
				t.Fatalf("status = %v, want %s; data=%#v", data["status"], tt.wantStatus, data)
			}
			gates := data["gates"].([]any)
			if len(gates) != len(tt.gates) {
				t.Fatalf("gates = %#v", gates)
			}
		})
	}
}

func TestFeishuUpsertRequiresMutatingConfirmation(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{
		"feishu", "app", "upsert",
		"--org", "acme",
		"--app-id", "cli_app",
		"--json",
	}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want empty", stdout)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	errBody := body["error"].(map[string]any)
	if errBody["code"] != "confirm_mutating_required" {
		t.Fatalf("error = %#v", errBody)
	}
}

func TestFeishuPlanDoesNotLeakSecretEnvValues(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{
		"feishu", "app", "plan",
		"--org", "acme",
		"--app-id", "cli_app",
		"--app-secret-env", "BFT_FEISHU_APP_SECRET",
		"--verification-token-env", "BFT_FEISHU_VERIFICATION_TOKEN",
		"--encrypt-key-env", "BFT_FEISHU_ENCRYPT_KEY",
		"--json",
	}, map[string]string{
		"BFT_FEISHU_APP_SECRET":         "raw-app-secret",
		"BFT_FEISHU_VERIFICATION_TOKEN": "raw-verification-token",
		"BFT_FEISHU_ENCRYPT_KEY":        "raw-encrypt-key",
	})
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	combined := stdout + stderr
	for _, secret := range []string{"raw-app-secret", "raw-verification-token", "raw-encrypt-key"} {
		if strings.Contains(combined, secret) {
			t.Fatalf("secret %q leaked in output: %s", secret, combined)
		}
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	attrs := body["data"].(map[string]any)["attrs"].(map[string]any)
	if attrs["app_secret_configured"] != true || attrs["verification_token_configured"] != true || attrs["encrypt_key_configured"] != true {
		t.Fatalf("attrs = %#v", attrs)
	}
}

func TestFeishuCommandsUseCLIAPIContracts(t *testing.T) {
	seen := map[string]map[string]any{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("%s Authorization = %q", r.URL.Path, r.Header.Get("Authorization"))
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode %s body: %v", r.URL.Path, err)
		}
		seen[r.URL.Path] = body
		switch r.URL.Path {
		case "/v1/cli/feishu/apps":
			writeOK(w, map[string]any{"mode": "feishu_app_upsert", "app": map[string]any{"app_id": "cli_app"}})
		case "/v1/cli/feishu/setup":
			writeOK(w, map[string]any{"mode": "feishu_setup", "connect": map[string]any{"id": "conn_setup"}})
		case "/v1/cli/feishu/connect":
			writeOK(w, map[string]any{"mode": "feishu_connect", "connect": map[string]any{"id": "conn_ensure"}})
		case "/v1/cli/feishu/checks":
			writeOK(w, map[string]any{"mode": "feishu_checks", "gates": []map[string]any{{"gate_id": "feishu.connect", "status": "ok"}}})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	cases := [][]string{
		{
			"feishu", "app", "upsert",
			"--org", "acme",
			"--app-id", "cli_app",
			"--display-name", "Bridge Bot",
			"--bot",
			"--sso",
			"--app-secret-env", "BFT_FEISHU_APP_SECRET",
			"--verification-token-env", "BFT_FEISHU_VERIFICATION_TOKEN",
			"--encrypt-key-env", "BFT_FEISHU_ENCRYPT_KEY",
			"--confirm-mutating",
			"--config", configPath,
			"--json",
		},
		{"feishu", "setup", "--org", "acme", "--project", "support", "--app-id", "cli_app", "--app-name", "Bridge Bot", "--connect-id", "conn_existing", "--config", configPath, "--json"},
		{"feishu", "connect", "ensure", "--org", "acme", "--project", "support", "--app-id", "cli_app", "--confirm-mutating", "--config", configPath, "--json"},
		{"feishu", "checks", "--org", "acme", "--project", "support", "--connect-id", "conn_existing", "--config", configPath, "--json"},
	}
	for _, args := range cases {
		exitCode, stdout, stderr := runCLI(t, args, map[string]string{
			"BFT_FEISHU_APP_SECRET":         "raw-app-secret",
			"BFT_FEISHU_VERIFICATION_TOKEN": "raw-verification-token",
			"BFT_FEISHU_ENCRYPT_KEY":        "raw-encrypt-key",
		})
		if exitCode != output.ExitOK {
			t.Fatalf("%v exit = %d stdout=%s stderr=%s", args, exitCode, stdout, stderr)
		}
	}

	appBody := seen["/v1/cli/feishu/apps"]
	if appBody["org"] != "acme" {
		t.Fatalf("app body = %#v", appBody)
	}
	attrs := appBody["attrs"].(map[string]any)
	if attrs["app_id"] != "cli_app" || attrs["display_name"] != "Bridge Bot" || attrs["bot_enabled"] != true || attrs["sso_enabled"] != true {
		t.Fatalf("attrs = %#v", attrs)
	}
	if attrs["app_secret"] != "raw-app-secret" || attrs["verification_token"] != "raw-verification-token" || attrs["encrypt_key"] != "raw-encrypt-key" {
		t.Fatalf("secret env attrs not passed to API body: %#v", attrs)
	}

	setupBody := seen["/v1/cli/feishu/setup"]
	if setupBody["org"] != "acme" || setupBody["project"] != "support" || setupBody["app_id"] != "cli_app" || setupBody["app_name"] != "Bridge Bot" || setupBody["connect_id"] != "conn_existing" || setupBody["ensure_connect"] != false {
		t.Fatalf("setup body = %#v", setupBody)
	}

	connectBody := seen["/v1/cli/feishu/connect"]
	if connectBody["org"] != "acme" || connectBody["project"] != "support" || connectBody["app_id"] != "cli_app" || connectBody["ensure_connect"] != true {
		t.Fatalf("connect body = %#v", connectBody)
	}

	checksBody := seen["/v1/cli/feishu/checks"]
	if checksBody["org"] != "acme" || checksBody["project"] != "support" || checksBody["connect_id"] != "conn_existing" {
		t.Fatalf("checks body = %#v", checksBody)
	}
}

func TestFeishuSetupRendersScopePresetInTextAndJSON(t *testing.T) {
	setupData := map[string]any{
		"mode":    "feishu_setup",
		"project": map[string]any{"name": "Support"},
		"action":  "existing",
		"required_scopes": []string{
			"im:message:readonly",
			"im:message.group_msg",
		},
		"batch_import_payload": map[string]any{
			"scopes": map[string]any{
				"tenant": []string{"im:message:readonly", "im:message.group_msg"},
			},
		},
		"optional_scopes": []map[string]any{
			{
				"scope": "im:resource",
				"label": "Upload images and files",
				"note":  "Only needed for richer outbound tools.",
			},
		},
		"event_subscriptions": []string{"im.message.receive_v1"},
		"manual_checklist":    []string{"Batch-import the required bot scopes.", "Publish the app version."},
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/feishu/setup" || r.Method != http.MethodPost {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		writeOK(w, setupData)
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	baseArgs := []string{"feishu", "setup", "--org", "acme", "--project", "support", "--config", configPath}
	exitCode, stdout, stderr := runCLI(t, append(append([]string{}, baseArgs...), "--output", "text"), nil)
	if exitCode != output.ExitOK {
		t.Fatalf("text exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	for _, want := range []string{
		"Feishu setup for Support",
		"Action: existing",
		"Required tenant scopes:\n  im:message:readonly\n  im:message.group_msg",
		"Batch-import JSON:\n{\n  \"scopes\": {",
		"Event subscriptions:\n  im.message.receive_v1",
		"Manual checklist:\n  1. Batch-import the required bot scopes.",
		"Optional scopes:\n  im:resource - Upload images and files",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("text output missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "Next: \n") {
		t.Fatalf("text output rendered an empty next action:\n%s", stdout)
	}

	exitCode, stdout, stderr = runCLI(t, append(append([]string{}, baseArgs...), "--json"), nil)
	if exitCode != output.ExitOK {
		t.Fatalf("json exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	required := data["required_scopes"].([]any)
	if len(required) != 2 || required[0] != "im:message:readonly" || required[1] != "im:message.group_msg" {
		t.Fatalf("required scopes = %#v", required)
	}
	payload := data["batch_import_payload"].(map[string]any)
	tenant := payload["scopes"].(map[string]any)["tenant"].([]any)
	if len(tenant) != 2 || tenant[1] != "im:message.group_msg" {
		t.Fatalf("batch import tenant scopes = %#v", tenant)
	}
}

func TestSlackSetupCommandShowsCredentialGuidance(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/slack/setup" || r.Method != http.MethodPost {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		writeOK(w, map[string]any{
			"mode":           "slack_setup",
			"slack_apps_url": "https://api.slack.com/apps",
			"redirect_url":   "https://salix.example.test/v1/im/slack/oauth/callback",
			"events_url":     "https://salix.example.test/v1/im/slack/events",
			"credential_guide": []map[string]any{
				{"field": "app_id", "flag": "--app-id", "source": "Slack app -> Basic Information -> App Credentials -> App ID"},
				{"field": "client_id", "flag": "--client-id", "source": "Slack app -> Basic Information -> App Credentials -> Client ID"},
				{"field": "client_secret", "flag": "--client-secret-env", "source": "Slack app -> Basic Information -> App Credentials -> Client Secret"},
				{"field": "signing_secret", "flag": "--signing-secret-env", "source": "Slack app -> Basic Information -> App Credentials -> Signing Secret"},
			},
			"create_connect_command":        "bft slack connects create --org acme --project support --app-id <app-id> --client-id <client-id> --client-secret-env BFT_SLACK_CLIENT_SECRET --signing-secret-env BFT_SLACK_SIGNING_SECRET --confirm-mutating",
			"create_worker_connect_command": "bft slack connects create --org acme --project support --app-id <app-id> --client-id <client-id> --client-secret-env BFT_SLACK_CLIENT_SECRET --signing-secret-env BFT_SLACK_SIGNING_SECRET --confirm-mutating --inbound-agent <salix-agent-id>",
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"slack", "setup", "--org", "acme", "--project", "support", "--config", configPath}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "Basic Information") || !strings.Contains(stdout, "--client-secret-env") || !strings.Contains(stdout, "Create router connect command:") || !strings.Contains(stdout, "Create worker connect command:") {
		t.Fatalf("stdout did not include Slack credential guidance:\n%s", stdout)
	}
	if strings.Contains(stdout, "[--inbound-agent") {
		t.Fatalf("stdout included a non-executable optional flag marker:\n%s", stdout)
	}
}

func TestMeetingCalendarStatusReadsBoundedProjection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/meetings/calendar/status" || r.Method != http.MethodGet {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		if r.URL.Query().Get("org") != "acme" || r.URL.Query().Get("project") != "support" || r.URL.Query().Get("connect_id") != "conn-calendar" || r.URL.Query().Get("limit") != "7" {
			t.Fatalf("query = %s", r.URL.RawQuery)
		}
		writeOK(w, map[string]any{
			"mode": "meeting_calendar_status",
			"checks": map[string]any{"gates": []map[string]any{{
				"gate_id": "bot.calendar", "status": "ok", "next_action": "No action required.",
			}}},
			"calendar": map[string]any{
				"health":     "ok",
				"reason":     "eligible_meetings_projected",
				"projection": map[string]any{"state": "active", "updated_at": float64(1_786_009_000_000)},
				"summary":    map[string]any{"candidate_count": 1, "returned_count": 1, "planned_count": 1, "plan_error_count": 0, "candidate_error_count": 0, "autojoin_error_count": 0},
				"events": []map[string]any{{
					"title": "Agenda https://docs.example.test/brief,Meet:[REDACTED_GOOGLE_MEET_URL]", "start_ms": float64(1_786_009_200_000),
					"plan":     map[string]any{"status": "planned", "preparation": map[string]any{"research_decision": "pending"}},
					"autojoin": map[string]any{"status": "not_started"},
				}},
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	args := []string{"meetings", "calendar", "status", "--org", "acme", "--project", "support", "--connect", "conn-calendar", "--limit", "7", "--config", configPath}
	exitCode, stdout, stderr := runCLI(t, append(append([]string{}, args...), "--json"), nil)
	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	calendar := data["calendar"].(map[string]any)
	if calendar["health"] != "ok" || len(calendar["events"].([]any)) != 1 {
		t.Fatalf("calendar = %#v", calendar)
	}
	if !strings.Contains(stdout, "https://docs.example.test/brief") || strings.Contains(stdout, "abc-defg-hij") {
		t.Fatalf("JSON output did not preserve the unrelated URL or leaked the Meet code:\n%s", stdout)
	}

	exitCode, stdout, stderr = runCLI(t, append(append([]string{}, args...), "--output", "text"), nil)
	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("text exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	for _, want := range []string{"Calendar health: ok", "Candidates: 1", "Agenda https://docs.example.test/brief,Meet:[REDACTED_GOOGLE_MEET_URL]", "plan=planned", "prep=pending", "autojoin=not_started"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("text output missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "abc-defg-hij") {
		t.Fatalf("text output leaked the Meet code:\n%s", stdout)
	}
}

func TestMeetingCalendarStatusFailsFastForUnboundedLimit(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"meetings", "calendar", "status", "--org", "acme", "--project", "support", "--limit", "51", "--json"}, nil)
	if exitCode != output.ExitUsage || stdout != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	if body["error"].(map[string]any)["code"] != "invalid_limit" {
		t.Fatalf("error = %#v", body)
	}
}

func TestMeetingCalendarStatusExitReflectsGateAndRuntimeHealth(t *testing.T) {
	tests := []struct {
		name     string
		gate     string
		health   string
		wantExit int
	}{
		{name: "healthy", gate: "ok", health: "ok", wantExit: output.ExitOK},
		{name: "pending scan", gate: "ok", health: "pending", wantExit: output.ExitNeedsManual},
		{name: "degraded runtime", gate: "ok", health: "degraded", wantExit: output.ExitNeedsManual},
		{name: "configuration gate", gate: "skipped", health: "not_ready", wantExit: output.ExitNeedsManual},
		{name: "backend unavailable", gate: "ok", health: "unavailable", wantExit: output.ExitUnavailable},
		{name: "connect lookup unavailable", gate: "skipped", health: "unavailable", wantExit: output.ExitUnavailable},
		{name: "policy backend unavailable", gate: "needs_manual", health: "unavailable", wantExit: output.ExitUnavailable},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			data := map[string]any{
				"checks":   map[string]any{"gates": []any{map[string]any{"status": test.gate}}},
				"calendar": map[string]any{"health": test.health},
			}
			if got := meetingCalendarStatusExit(data); got != test.wantExit {
				t.Fatalf("exit = %d, want %d", got, test.wantExit)
			}
		})
	}
}

func TestMeetingCalendarStatusStoppedWorkerReturns2InJSONAndText(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/meetings/calendar/status" || r.Method != http.MethodGet {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		writeOK(w, map[string]any{
			"mode": "meeting_calendar_status",
			"checks": map[string]any{"gates": []map[string]any{{
				"gate_id": "bot.calendar", "status": "ok", "next_action": "No action required.",
			}}},
			"calendar": map[string]any{
				"health": "degraded",
				"reason": "calendar_worker_not_running",
				"runtime": map[string]any{
					"status": "not_running", "configured": true, "running": false,
				},
				"projection": map[string]any{
					"state": "active", "candidate_count": 1, "returned_count": 1,
				},
				"summary": map[string]any{
					"candidate_count": 1, "returned_count": 1, "planned_count": 1,
					"plan_error_count": 0, "candidate_error_count": 0, "autojoin_error_count": 0,
				},
				"events": []map[string]any{{
					"title":    "Comma Team's Stand-up Meeting",
					"plan":     map[string]any{"status": "planned"},
					"autojoin": map[string]any{"status": "not_started"},
				}},
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	baseArgs := []string{"meetings", "calendar", "status", "--org", "acme", "--project", "support", "--config", configPath}
	for _, outputArgs := range [][]string{{"--json"}, {"--output", "text"}} {
		exitCode, stdout, stderr := runCLI(t, append(append([]string{}, baseArgs...), outputArgs...), nil)
		if exitCode != output.ExitNeedsManual || stderr != "" {
			t.Fatalf("args=%v exit=%d stdout=%s stderr=%s", outputArgs, exitCode, stdout, stderr)
		}
		for _, want := range []string{"degraded", "calendar_worker_not_running", "not_running"} {
			if !strings.Contains(stdout, want) {
				t.Fatalf("args=%v output missing %q: %s", outputArgs, want, stdout)
			}
		}
	}
}

func TestMeetingCalendarStatusUnavailableReturns69InJSONAndText(t *testing.T) {
	tests := []struct {
		name        string
		gateStatus  string
		reasonClass string
		reason      string
	}{
		{
			name:        "backend unavailable",
			gateStatus:  "needs_manual",
			reasonClass: "calendar_backend_unavailable",
			reason:      "calendar_status_backend_unavailable",
		},
		{
			name:       "invalid raw DTO",
			gateStatus: "ok",
			reason:     "calendar_status_invalid_response",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/cli/meetings/calendar/status" || r.Method != http.MethodGet {
					t.Fatalf("request = %s %s", r.Method, r.URL.Path)
				}
				if r.Header.Get("Authorization") != "Bearer from-config-token" {
					t.Fatalf("Authorization = %q", r.Header.Get("Authorization"))
				}
				writeOK(w, map[string]any{
					"mode": "meeting_calendar_status",
					"checks": map[string]any{"gates": []map[string]any{{
						"gate_id": "bot.calendar", "status": test.gateStatus, "reason_class": test.reasonClass,
					}}},
					"calendar": map[string]any{
						"health": "unavailable",
						"reason": test.reason,
						"projection": map[string]any{
							"state": "unavailable", "candidate_count": 0, "returned_count": 0,
						},
						"summary": map[string]any{
							"candidate_count": 0, "returned_count": 0, "planned_count": 0,
							"plan_error_count": 0, "candidate_error_count": 0, "autojoin_error_count": 0,
						},
						"events": []map[string]any{},
					},
				})
			}))
			defer server.Close()

			configPath := filepath.Join(t.TempDir(), "cli.json")
			if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
				t.Fatalf("persist config: %v", err)
			}

			baseArgs := []string{"meetings", "calendar", "status", "--org", "acme", "--project", "support", "--config", configPath}
			for _, outputArgs := range [][]string{{"--json"}, {"--output", "text"}} {
				exitCode, stdout, stderr := runCLI(t, append(append([]string{}, baseArgs...), outputArgs...), nil)
				if exitCode != output.ExitUnavailable || stderr != "" {
					t.Fatalf("args=%v exit=%d stdout=%s stderr=%s", outputArgs, exitCode, stdout, stderr)
				}
				for _, want := range []string{"unavailable", test.reason} {
					if !strings.Contains(stdout, want) {
						t.Fatalf("args=%v output missing %q: %s", outputArgs, want, stdout)
					}
				}
			}
		})
	}
}

func TestAgentsListCommandShowsRuntimeIdentity(t *testing.T) {
	agentsPath := "/v1/orgs/acme/projects/support/agents"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != agentsPath || r.Method != http.MethodGet {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		if r.URL.Query().Get("role") != "worker" || r.URL.Query().Get("filter") != "codex" || r.URL.Query().Get("limit") != "20" || r.URL.Query().Get("cursor") != "page-one" {
			t.Fatalf("query = %s", r.URL.RawQuery)
		}
		writeOK(w, map[string]any{
			"mode":        "project_agents_list",
			"next_cursor": "page-two",
			"agents": []map[string]any{{
				"id":             "bft-agent-1",
				"salix_agent_id": "agent_healthy",
				"name":           "codex-bft",
				"role":           "worker",
				"status":         "active",
				"runtime_config": map[string]any{
					"kind":              "external",
					"provider":          "codex",
					"device_id":         "dev_ZL",
					"runtime_id":        "runtime_codex",
					"device_runtime_id": "dev_runtime_codex",
				},
				"runtime": map[string]any{
					"kind":              "external",
					"status":            "ready",
					"device_id":         "dev_ZL",
					"runtime_id":        "runtime_codex",
					"device_runtime_id": "dev_runtime_codex",
					"connector_run_id":  "run_ZL",
					"device_status":     "connected",
				},
			}},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"agents", "list",
		"--org", "acme",
		"--project", "support",
		"--role", "worker",
		"--filter", "codex",
		"--limit", "20",
		"--cursor", "page-one",
		"--config", configPath,
	}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	for _, want := range []string{"next_cursor: page-two", "salix_agent_id", "agent_healthy", "runtime_status", "ready", "run_ZL", "dev_runtime_codex"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("agents output missing %q:\n%s", want, stdout)
		}
	}
}

func TestAgentsRuntimesAndRebindCommandsUseProjectAPIContracts(t *testing.T) {
	runtimesPath := "/v1/orgs/acme/projects/support/agents/runtimes"
	rebindPath := "/v1/orgs/acme/projects/support/agents/agt_codex/runtime"
	var sawRuntimes bool
	var seenRebind map[string]any

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == runtimesPath && r.Method == http.MethodGet:
			sawRuntimes = true
			writeOK(w, map[string]any{
				"mode": "project_agent_runtimes_list",
				"runtimes": []map[string]any{{
					"device_runtime_id": "devrt_codex_ZL",
					"device_id":         "dev_ZL",
					"device_name":       "Mac Studio",
					"runtime_id":        "runtime_codex",
					"status":            "available",
					"ready":             true,
					"version":           "codex-test",
					"connector_run_id":  "connrun_ZL",
					"working_dir":       "/Users/test/project",
					"model":             "claude-sonnet-4",
					"model_provider":    "anthropic",
				}, {
					"device_runtime_id":    "devrt_codex_not_ready",
					"device_id":            "dev_ZL",
					"device_name":          "Mac Studio",
					"runtime_id":           "runtime_codex_not_ready",
					"status":               "available",
					"ready":                false,
					"version":              "codex-test",
					"connector_run_id":     "connrun_ZL",
					"app_server_startable": true,
					"auth_ready":           true,
				}},
			})

		case r.URL.Path == rebindPath && r.Method == http.MethodPatch:
			if err := json.NewDecoder(r.Body).Decode(&seenRebind); err != nil {
				t.Fatalf("decode rebind body: %v", err)
			}
			writeOK(w, map[string]any{
				"mode": "project_agent_runtime_rebind",
				"agent": map[string]any{
					"id":             "bft-agent-1",
					"salix_agent_id": "agent_healthy",
					"name":           "codex-bft",
					"role":           "worker",
					"status":         "active",
					"runtime": map[string]any{
						"kind":              "external",
						"status":            "ready",
						"device_id":         "dev_ZL",
						"runtime_id":        "runtime_codex",
						"device_runtime_id": "devrt_codex_ZL",
						"connector_run_id":  "connrun_ZL",
						"device_status":     "connected",
					},
				},
			})

		default:
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"agents", "runtimes",
		"--org", "acme",
		"--project", "support",
		"--config", configPath,
	}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("runtimes exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !sawRuntimes || !strings.Contains(stdout, "devrt_codex_ZL") || !strings.Contains(stdout, "connrun_ZL") {
		t.Fatalf("runtimes output = %s", stdout)
	}
	if strings.Contains(stdout, "devrt_codex_not_ready") {
		t.Fatalf("runtimes default output should include only bindable runtimes:\n%s", stdout)
	}

	exitCode, stdout, stderr = runCLI(t, []string{
		"agents", "runtimes",
		"--org", "acme",
		"--project", "support",
		"--include-unavailable",
		"--config", configPath,
	}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("runtimes include unavailable exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "devrt_codex_not_ready") || !strings.Contains(stdout, "false") {
		t.Fatalf("runtimes include unavailable output = %s", stdout)
	}

	exitCode, stdout, stderr = runCLI(t, []string{
		"agents", "rebind",
		"--org", "acme",
		"--project", "support",
		"--agent", "agt_codex",
		"--runtime", "devrt_codex_ZL",
		"--device", "dev_ZL",
		"--confirm-mutating",
		"--config", configPath,
	}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("rebind exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if seenRebind["runtime"] != "devrt_codex_ZL" || seenRebind["device"] != "dev_ZL" {
		t.Fatalf("rebind body = %#v", seenRebind)
	}
	if !strings.Contains(stdout, "Agent runtime rebind accepted. Reconcile pending.") ||
		!strings.Contains(stdout, "devrt_codex_ZL") {
		t.Fatalf("rebind output = %s", stdout)
	}
}

func TestAgentsCreateCommandUsesProjectAPIContract(t *testing.T) {
	agentsPath := "/v1/orgs/acme/projects/support/agents"
	var seenBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != agentsPath || r.Method != http.MethodPost {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("Authorization = %q", r.Header.Get("Authorization"))
		}
		if err := json.NewDecoder(r.Body).Decode(&seenBody); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		writeOK(w, map[string]any{
			"mode": "project_agent_create",
			"agent": map[string]any{
				"id":             "bft-agent-created",
				"salix_agent_id": "agent_created",
				"name":           "codex-worker",
				"role":           "worker",
				"status":         "active",
				"runtime_config": map[string]any{
					"kind":              "external",
					"provider":          "codex",
					"device_id":         "dev_ZL",
					"runtime_id":        "runtime_codex",
					"device_runtime_id": "devrt_codex_ZL",
				},
				"runtime": map[string]any{
					"kind":              "external",
					"status":            "ready",
					"device_id":         "dev_ZL",
					"runtime_id":        "runtime_codex",
					"device_runtime_id": "devrt_codex_ZL",
					"connector_run_id":  "connrun_ZL",
					"device_status":     "connected",
				},
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"agents", "create",
		"--org", "acme",
		"--project", "support",
		"--name", "codex-worker",
		"--role", "worker",
		"--runtime-kind", "external",
		"--device-id", "dev_ZL",
		"--runtime-id", "runtime_codex",
		"--device-runtime-id", "devrt_codex_ZL",
		"--confirm-mutating",
		"--config", configPath,
	}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	for _, want := range []string{"Agent created.", "agent_created", "runtime_status", "ready", "devrt_codex_ZL"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("create output missing %q:\n%s", want, stdout)
		}
	}
	if seenBody["org"] != nil || seenBody["project"] != nil {
		t.Fatalf("project identifiers should be path params, body = %#v", seenBody)
	}
	runtimeConfig, _ := seenBody["runtime_config"].(map[string]any)
	if seenBody["name"] != "codex-worker" ||
		seenBody["role"] != "worker" ||
		runtimeConfig["kind"] != "external" ||
		runtimeConfig["provider"] != "codex" ||
		runtimeConfig["device_id"] != "dev_ZL" ||
		runtimeConfig["runtime_id"] != "runtime_codex" ||
		runtimeConfig["device_runtime_id"] != "devrt_codex_ZL" {
		t.Fatalf("create body = %#v", seenBody)
	}
}

func TestAgentsCreateCommandRequiresConfirmation(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: "https://teams.example.test", Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"agents", "create",
		"--org", "acme",
		"--project", "support",
		"--name", "codex-worker",
		"--runtime-kind", "external",
		"--device-id", "dev_ZL",
		"--runtime-id", "runtime_codex",
		"--device-runtime-id", "devrt_codex_ZL",
		"--config", configPath,
		"--json",
	}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "confirm_mutating_required") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestAgentsCreateCommandRejectsInvalidLocalRuntimeFlags(t *testing.T) {
	tests := []struct {
		name string
		args []string
		code string
	}{
		{
			name: "role",
			args: []string{"--role", "meeting"},
			code: "invalid_role",
		},
		{
			name: "runtime kind",
			args: []string{"--runtime-kind", "external.codex"},
			code: "invalid_runtime_kind",
		},
		{
			name: "runtime provider",
			args: []string{"--runtime-kind", "external", "--runtime-provider", "openai", "--device-id", "dev_ZL", "--runtime-id", "runtime_codex", "--device-runtime-id", "devrt_codex_ZL"},
			code: "invalid_runtime_provider",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			args := []string{
				"agents", "create",
				"--org", "acme",
				"--project", "support",
				"--name", "codex-worker",
				"--json",
			}
			args = append(args, tt.args...)

			exitCode, stdout, stderr := runCLI(t, args, nil)
			if exitCode != output.ExitUsage {
				t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
			}
			if stdout != "" {
				t.Fatalf("stdout = %q, want empty", stdout)
			}
			var body map[string]any
			decodeJSON(t, stderr, &body)
			if body["error"].(map[string]any)["code"] != tt.code {
				t.Fatalf("stderr body = %#v, want code %s", body, tt.code)
			}
		})
	}
}

func TestSlackConnectCommandsUseProjectAPIContracts(t *testing.T) {
	seenBodies := map[string]map[string]any{}
	seenMethods := map[string]string{}
	connectsPath := "/v1/orgs/acme/projects/support/im/slack/connects"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("%s Authorization = %q", r.URL.Path, r.Header.Get("Authorization"))
		}
		seenMethods[r.URL.Path] = r.Method
		if r.Body != nil && (r.Method == http.MethodPost || r.Method == http.MethodPatch) && (r.URL.Path == connectsPath || r.URL.Path == connectsPath+"/conn_slack_1") {
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode %s body: %v", r.URL.Path, err)
			}
			seenBodies[r.URL.Path] = body
		}

		switch r.URL.Path {
		case connectsPath:
			switch r.Method {
			case http.MethodGet:
				writeOK(w, map[string]any{"mode": "project_im_connects_list", "connects": []map[string]any{{
					"connect_id":       "conn_slack_1",
					"provider":         "slack",
					"app_id":           "A123",
					"app_name":         "Project Worker",
					"workspace_name":   "JinfeiTest",
					"bot_user_id":      "UWORKERBOT",
					"bot_username":     "project_worker_bot",
					"inbound_agent_id": "agent-worker",
					"install_status":   "installed",
				}}})
			case http.MethodPost:
				writeOK(w, map[string]any{
					"mode":      "project_im_connect_create",
					"oauth_url": "https://slack.example.test/oauth",
					"connect": map[string]any{
						"connect_id":                "conn_slack_1",
						"provider":                  "slack",
						"app_id":                    "A123",
						"workspace_name":            "JinfeiTest",
						"bot_user_id":               "UWORKERBOT",
						"bot_username":              "project_worker_bot",
						"inbound_agent_id":          "agent-worker",
						"install_status":            "pending_oauth",
						"client_secret_configured":  true,
						"signing_secret_configured": true,
					},
				})
			default:
				t.Fatalf("method for %s = %s", r.URL.Path, r.Method)
			}
		case connectsPath + "/conn_slack_1/disable":
			if r.Method != http.MethodPost {
				t.Fatalf("disable method = %s", r.Method)
			}
			writeOK(w, map[string]any{"mode": "project_im_connect_disable", "connect": map[string]any{"connect_id": "conn_slack_1", "disabled_at": "now"}})
		case connectsPath + "/conn_slack_1/enable":
			if r.Method != http.MethodPost {
				t.Fatalf("enable method = %s", r.Method)
			}
			writeOK(w, map[string]any{"mode": "project_im_connect_enable", "connect": map[string]any{"connect_id": "conn_slack_1"}})
		case connectsPath + "/conn_slack_1":
			switch r.Method {
			case http.MethodPatch:
				writeOK(w, map[string]any{"mode": "project_im_connect_update", "connect": map[string]any{
					"connect_id":       "conn_slack_1",
					"provider":         "slack",
					"app_id":           "A123",
					"workspace_name":   "JinfeiTest",
					"bot_user_id":      "UWORKERBOT",
					"inbound_agent_id": "agent-healthy",
					"install_status":   "installed",
				}})
			case http.MethodDelete:
				writeOK(w, map[string]any{"mode": "project_im_connect_delete", "connect_id": "conn_slack_1"})
			default:
				t.Fatalf("method for %s = %s", r.URL.Path, r.Method)
			}
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"slack", "connects", "list", "--org", "acme", "--project", "support", "--config", configPath}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("list text exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "install_status") || !strings.Contains(stdout, "installed") {
		t.Fatalf("list output did not expose install status:\n%s", stdout)
	}
	if !strings.Contains(stdout, "workspace") || !strings.Contains(stdout, "JinfeiTest") {
		t.Fatalf("list output did not expose workspace:\n%s", stdout)
	}
	if !strings.Contains(stdout, "bot_user_id") || !strings.Contains(stdout, "UWORKERBOT") {
		t.Fatalf("list output did not expose Slack bot identity:\n%s", stdout)
	}

	exitCode, stdout, stderr = runCLI(t, []string{
		"slack", "connects", "create",
		"--org", "acme",
		"--project", "support",
		"--app-name", "Project Worker",
		"--app-id", "A123",
		"--client-id", "123.abc",
		"--client-secret-env", "BFT_SLACK_CLIENT_SECRET",
		"--signing-secret-env", "BFT_SLACK_SIGNING_SECRET",
		"--inbound-agent", "agent-worker",
		"--confirm-mutating",
		"--config", configPath,
	}, map[string]string{
		"BFT_SLACK_CLIENT_SECRET":  "raw-client-secret",
		"BFT_SLACK_SIGNING_SECRET": "raw-signing-secret",
	})
	if exitCode != output.ExitOK {
		t.Fatalf("create text exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "Workspace: JinfeiTest") {
		t.Fatalf("create output did not expose workspace:\n%s", stdout)
	}
	if !strings.Contains(stdout, "Bot user: UWORKERBOT (@project_worker_bot)") {
		t.Fatalf("create output did not expose Slack bot identity:\n%s", stdout)
	}

	cases := [][]string{
		{"slack", "connects", "list", "--org", "acme", "--project", "support", "--config", configPath, "--json"},
		{
			"slack", "connects", "create",
			"--org", "acme",
			"--project", "support",
			"--app-name", "Project Worker",
			"--app-id", "A123",
			"--client-id", "123.abc",
			"--client-secret-env", "BFT_SLACK_CLIENT_SECRET",
			"--signing-secret-env", "BFT_SLACK_SIGNING_SECRET",
			"--inbound-agent", "agent-worker",
			"--confirm-mutating",
			"--config", configPath,
			"--json",
		},
		{"slack", "connects", "update", "--org", "acme", "--project", "support", "--connect", "conn_slack_1", "--inbound-agent", "agent-healthy", "--confirm-mutating", "--config", configPath, "--json"},
		{"slack", "connects", "disable", "--org", "acme", "--project", "support", "--connect", "conn_slack_1", "--confirm-mutating", "--config", configPath, "--json"},
		{"slack", "connects", "enable", "--org", "acme", "--project", "support", "--connect", "conn_slack_1", "--confirm-mutating", "--config", configPath, "--json"},
		{"slack", "connects", "delete", "--org", "acme", "--project", "support", "--connect", "conn_slack_1", "--confirm-mutating", "--config", configPath, "--json"},
	}

	for _, args := range cases {
		exitCode, stdout, stderr := runCLI(t, args, map[string]string{
			"BFT_SLACK_CLIENT_SECRET":  "raw-client-secret",
			"BFT_SLACK_SIGNING_SECRET": "raw-signing-secret",
		})
		if exitCode != output.ExitOK {
			t.Fatalf("%v exit = %d stdout=%s stderr=%s", args, exitCode, stdout, stderr)
		}
		if strings.Contains(stdout, "raw-client-secret") || strings.Contains(stdout, "raw-signing-secret") {
			t.Fatalf("%v leaked a Slack secret: %s", args, stdout)
		}
	}

	createBody := seenBodies[connectsPath]
	if createBody["org"] != nil || createBody["project"] != nil {
		t.Fatalf("project identifiers should be path params, body = %#v", createBody)
	}
	if createBody["app_id"] != "A123" || createBody["client_id"] != "123.abc" || createBody["app_name"] != "Project Worker" || createBody["inbound_agent_id"] != "agent-worker" {
		t.Fatalf("create body = %#v", createBody)
	}
	if createBody["client_secret"] != "raw-client-secret" || createBody["signing_secret"] != "raw-signing-secret" {
		t.Fatalf("secret env values not sent to project API: %#v", createBody)
	}
	updateBody := seenBodies[connectsPath+"/conn_slack_1"]
	if updateBody["inbound_agent_id"] != "agent-healthy" || len(updateBody) != 1 {
		t.Fatalf("update body should only carry inbound_agent_id: %#v", updateBody)
	}
	if seenMethods[connectsPath+"/conn_slack_1"] != http.MethodDelete {
		t.Fatalf("delete method not observed: %#v", seenMethods)
	}
}

func TestSlackConnectTextRequiresBotUserIDForBotLine(t *testing.T) {
	withoutBotID := slackConnectText("Slack connect created.", map[string]any{
		"connect": map[string]any{
			"connect_id":   "conn_slack_1",
			"bot_username": "project_worker_bot",
		},
	})
	if strings.Contains(withoutBotID, "Bot user:") {
		t.Fatalf("username-only Slack connect should not claim a bot user id:\n%s", withoutBotID)
	}

	withBotID := slackConnectText("Slack connect created.", map[string]any{
		"connect": map[string]any{
			"connect_id":   "conn_slack_1",
			"bot_user_id":  "UWORKERBOT",
			"bot_username": "project_worker_bot",
		},
	})
	if !strings.Contains(withBotID, "Bot user: UWORKERBOT (@project_worker_bot)") {
		t.Fatalf("Slack connect with bot_user_id should expose bot identity:\n%s", withBotID)
	}
}

func TestSlackConnectCommandsValidateLocalMutationInputs(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: "https://teams.example.test", Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"slack", "connects", "create",
		"--org", "acme",
		"--project", "support",
		"--app-id", "A123",
		"--client-id", "123.abc",
		"--client-secret-env", "BFT_SLACK_CLIENT_SECRET",
		"--signing-secret-env", "BFT_SLACK_SIGNING_SECRET",
		"--config", configPath,
		"--json",
	}, map[string]string{
		"BFT_SLACK_CLIENT_SECRET":  "raw-client-secret",
		"BFT_SLACK_SIGNING_SECRET": "raw-signing-secret",
	})
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "confirm_mutating_required") {
		t.Fatalf("stderr = %q", stderr)
	}

	exitCode, stdout, stderr = runCLI(t, []string{
		"slack", "connects", "create",
		"--org", "acme",
		"--project", "support",
		"--app-id", "A123",
		"--client-id", "123.abc",
		"--client-secret-env", "BFT_SLACK_CLIENT_SECRET",
		"--signing-secret-env", "BFT_SLACK_SIGNING_SECRET",
		"--confirm-mutating",
		"--config", configPath,
		"--json",
	}, map[string]string{
		"BFT_SLACK_SIGNING_SECRET": "raw-signing-secret",
	})
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "empty_client_secret_env") {
		t.Fatalf("stderr = %q", stderr)
	}

	exitCode, stdout, stderr = runCLI(t, []string{
		"slack", "connects", "disable",
		"--org", "acme",
		"--project", "support",
		"--connect", "conn_slack_1",
		"--config", configPath,
		"--json",
	}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "confirm_mutating_required") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestSlackConnectCommandsSurfaceProjectAPIErrors(t *testing.T) {
	connectsPath := "/v1/orgs/acme/projects/support/im/slack/connects"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != connectsPath || r.Method != http.MethodPost {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		writeAPIError(w, http.StatusConflict, "provider_app_in_use", "Slack app is already connected to another project.")
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"slack", "connects", "create",
		"--org", "acme",
		"--project", "support",
		"--app-id", "A123",
		"--client-id", "123.abc",
		"--client-secret-env", "BFT_SLACK_CLIENT_SECRET",
		"--signing-secret-env", "BFT_SLACK_SIGNING_SECRET",
		"--confirm-mutating",
		"--config", configPath,
		"--json",
	}, map[string]string{
		"BFT_SLACK_CLIENT_SECRET":  "raw-client-secret",
		"BFT_SLACK_SIGNING_SECRET": "raw-signing-secret",
	})
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "provider_app_in_use") || !strings.Contains(stderr, "Slack app is already connected") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestConversationCommandsUseCLIAPIContracts(t *testing.T) {
	seen := map[string]string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("%s Authorization = %q", r.URL.Path, r.Header.Get("Authorization"))
		}
		seen[r.URL.Path] = r.URL.RawQuery

		switch r.URL.Path {
		case "/v1/cli/conversations":
			if r.URL.Query().Get("org") != "acme" || r.URL.Query().Get("project") != "support" || r.URL.Query().Get("limit") != "10" {
				t.Fatalf("list query = %s", r.URL.RawQuery)
			}
			writeOK(w, map[string]any{
				"mode": "conversations_list",
				"conversations": []map[string]any{
					{"conversation_id": "task-1", "kind": "agent_task", "status": "active", "title": "Task 1"},
				},
			})
		case "/v1/cli/conversations/task-1":
			if r.URL.Query().Get("message_limit") != "3" {
				t.Fatalf("show query = %s", r.URL.RawQuery)
			}
			writeOK(w, map[string]any{
				"mode":         "conversation_show",
				"conversation": map[string]any{"conversation_id": "task-1", "kind": "agent_task"},
				"participants": []map[string]any{{"participant_id": "worker", "actor_type": "agent"}},
				"messages":     []map[string]any{{"message_id": "msg-1"}},
			})
		case "/v1/cli/conversations/task-1/messages":
			if r.Method == http.MethodPost {
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatalf("decode send body: %v", err)
				}
				if body["org"] != "acme" || body["project"] != "support" || body["text"] != "run fresh checks" || body["request_id"] != "smoke-1" {
					t.Fatalf("send body = %#v", body)
				}
				writeOK(w, map[string]any{"mode": "conversation_send", "message": map[string]any{"message_id": "msg-sent"}})
				break
			}
			if r.Method != http.MethodGet || r.URL.Query().Get("limit") != "4" {
				t.Fatalf("messages request = %s %s", r.Method, r.URL.RawQuery)
			}
			writeOK(w, map[string]any{
				"mode":     "conversation_messages",
				"messages": []map[string]any{{"message_id": "msg-1", "participant_id": "worker"}},
			})
		case "/v1/cli/conversations/task-1/trace":
			if r.URL.Query().Get("limit") != "5" || r.URL.Query().Get("participant") != "worker" {
				t.Fatalf("trace query = %s", r.URL.RawQuery)
			}
			writeOK(w, map[string]any{
				"mode":                 "conversation_trace",
				"trace_agent_id":       "agent-worker",
				"trace_session_id":     "im-task-1",
				"trace_participant_id": "worker",
				"trace":                map[string]any{"events": []map[string]any{{"method": "turn/completed"}}},
			})
		case "/v1/cli/conversations/task-1/delivery":
			if r.URL.Query().Get("limit") != "6" ||
				r.URL.Query().Get("participant") != "worker" ||
				r.URL.Query().Get("message") != "msg-1" {
				t.Fatalf("delivery query = %s", r.URL.RawQuery)
			}
			writeOK(w, map[string]any{
				"mode":            "conversation_delivery",
				"conversation_id": "task-1",
				"participant_id":  "worker",
				"delivery": map[string]any{
					"deliveries": []map[string]any{
						{
							"message_id":            "msg-1",
							"target_actor_type":     "agent",
							"status":                "delivered",
							"target_session_id":     "im-task-1",
							"target_participant_id": "worker",
							"session":               map[string]any{"exists": true, "status": "ready"},
						},
					},
				},
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	cases := [][]string{
		{"conversations", "list", "--org", "acme", "--project", "support", "--limit", "10", "--config", configPath, "--json"},
		{"conversations", "show", "--org", "acme", "--project", "support", "--conversation", "task-1", "--message-limit", "3", "--config", configPath, "--json"},
		{"conversations", "messages", "--org", "acme", "--project", "support", "--conversation", "task-1", "--limit", "4", "--config", configPath, "--json"},
		{"conversations", "send", "--org", "acme", "--project", "support", "--conversation", "task-1", "--text", " run fresh checks ", "--request", "smoke-1", "--confirm-mutating", "--config", configPath, "--json"},
		{"conversations", "trace", "--org", "acme", "--project", "support", "--conversation", "task-1", "--participant", "worker", "--limit", "5", "--config", configPath, "--json"},
		{"conversations", "delivery", "--org", "acme", "--project", "support", "--conversation", "task-1", "--participant", "worker", "--message", "msg-1", "--limit", "6", "--config", configPath, "--json"},
	}

	for _, args := range cases {
		exitCode, stdout, stderr := runCLI(t, args, nil)
		if exitCode != output.ExitOK {
			t.Fatalf("%v exit = %d stdout=%s stderr=%s", args, exitCode, stdout, stderr)
		}
		var body map[string]any
		decodeJSON(t, stdout, &body)
		if body["ok"] != true {
			t.Fatalf("%v body = %#v", args, body)
		}
	}

	exitCode, stdout, stderr := runCLI(t, []string{"conversations", "trace", "--org", "acme", "--project", "support", "--conversation", "task-1", "--participant", "worker", "--limit", "5", "--config", configPath}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("trace text exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "Trace participant: worker") || !strings.Contains(stdout, "Trace session: im-task-1") {
		t.Fatalf("trace text output = %q", stdout)
	}

	exitCode, stdout, stderr = runCLI(t, []string{"conversations", "delivery", "--org", "acme", "--project", "support", "--conversation", "task-1", "--participant", "worker", "--message", "msg-1", "--limit", "6", "--config", configPath}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("delivery text exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "Delivery participant: worker") ||
		!strings.Contains(stdout, "msg-1") ||
		!strings.Contains(stdout, "ready") {
		t.Fatalf("delivery text output = %q", stdout)
	}

	for _, path := range []string{
		"/v1/cli/conversations",
		"/v1/cli/conversations/task-1",
		"/v1/cli/conversations/task-1/messages",
		"/v1/cli/conversations/task-1/trace",
		"/v1/cli/conversations/task-1/delivery",
	} {
		if _, ok := seen[path]; !ok {
			t.Fatalf("missing request for %s; seen=%#v", path, seen)
		}
	}
}

func TestMeetingsReplayDefaultsToNoModelDeliveryFreePlan(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/cli/meetings/replay" {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("Authorization = %q", r.Header.Get("Authorization"))
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if body["org"] != "acme" || body["project"] != "support" || body["meeting_id"] != "meeting-123" || body["request_id"] != "request-123" {
			t.Fatalf("body = %#v", body)
		}
		if body["run_model"] != false {
			t.Fatalf("run_model = %#v", body["run_model"])
		}
		if body["confirm_model_replay"] != false {
			t.Fatalf("confirm_model_replay = %#v", body["confirm_model_replay"])
		}
		writeOK(w, map[string]any{
			"mode": "meeting_summary_replay",
			"replay": map[string]any{
				"run_id":          "run-1",
				"meeting_id":      "meeting-123",
				"mode":            "plan_only",
				"status":          "ok",
				"passed":          true,
				"delivery_writes": false,
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"meetings", "replay",
		"--org", "acme",
		"--project", "support",
		"--meeting", "meeting-123",
		"--request", "request-123",
		"--config", configPath,
		"--json",
	}, nil)

	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, `"delivery_writes": false`) || !strings.Contains(stdout, `"passed": true`) {
		t.Fatalf("stdout = %q", stdout)
	}
}

func TestMeetingsReplayRequiresExplicitConfirmationForModelCalls(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{
		"meetings", "replay",
		"--org", "acme",
		"--project", "support",
		"--meeting", "meeting-123",
		"--request", "request-123",
		"--run-model",
		"--json",
	}, nil)

	if exitCode != output.ExitUsage || stdout != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stderr, "confirm_mutating_required") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestMeetingsReplaySendsModelConfirmationToTheAPI(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if body["run_model"] != true || body["confirm_model_replay"] != true {
			t.Fatalf("body = %#v", body)
		}
		writeOK(w, map[string]any{
			"mode":   "meeting_summary_replay",
			"replay": map[string]any{"status": "ok", "passed": true, "delivery_writes": false},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"meetings", "replay",
		"--org", "acme",
		"--project", "support",
		"--meeting", "meeting-123",
		"--request", "request-123",
		"--run-model",
		"--confirm-mutating",
		"--config", configPath,
		"--json",
	}, nil)

	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
}

func TestConversationCommandsMapAPIErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer from-config-token" {
			t.Fatalf("%s Authorization = %q", r.URL.Path, r.Header.Get("Authorization"))
		}

		switch r.URL.Path {
		case "/v1/cli/conversations/missing-task":
			writeAPIError(w, http.StatusNotFound, "conversation_not_found", "Conversation not found.")
		case "/v1/cli/conversations":
			writeAPIError(w, http.StatusBadRequest, "invalid_limit", "Limit must be a positive integer.")
		case "/v1/cli/conversations/task-1/trace":
			writeAPIError(w, http.StatusServiceUnavailable, "trace_unavailable", "Conversation trace is unavailable.")
		case "/v1/cli/conversations/ambiguous-task/trace":
			writeAPIError(w, http.StatusBadRequest, "trace_participant_required", "Pass a conversation participant id to select the trace session.")
		case "/v1/cli/conversations/no-trace/trace":
			writeAPIError(w, http.StatusNotFound, "trace_session_not_found", "Conversation trace session not found.")
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	cases := []struct {
		name     string
		args     []string
		exitCode int
		code     string
	}{
		{
			name:     "not found",
			args:     []string{"conversations", "show", "--org", "acme", "--project", "support", "--conversation", "missing-task", "--config", configPath, "--json"},
			exitCode: output.ExitNotFound,
			code:     "conversation_not_found",
		},
		{
			name:     "bad request",
			args:     []string{"conversations", "list", "--org", "acme", "--project", "support", "--limit", "1", "--config", configPath, "--json"},
			exitCode: output.ExitUsage,
			code:     "invalid_limit",
		},
		{
			name:     "unavailable",
			args:     []string{"conversations", "trace", "--org", "acme", "--project", "support", "--conversation", "task-1", "--limit", "1", "--config", configPath, "--json"},
			exitCode: output.ExitUnavailable,
			code:     "trace_unavailable",
		},
		{
			name:     "participant required",
			args:     []string{"conversations", "trace", "--org", "acme", "--project", "support", "--conversation", "ambiguous-task", "--limit", "1", "--config", configPath, "--json"},
			exitCode: output.ExitUsage,
			code:     "trace_participant_required",
		},
		{
			name:     "trace session not found",
			args:     []string{"conversations", "trace", "--org", "acme", "--project", "support", "--conversation", "no-trace", "--limit", "1", "--config", configPath, "--json"},
			exitCode: output.ExitNotFound,
			code:     "trace_session_not_found",
		},
	}

	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			exitCode, stdout, stderr := runCLI(t, tt.args, nil)
			if exitCode != tt.exitCode {
				t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
			}
			if stdout != "" {
				t.Fatalf("stdout = %q, want empty", stdout)
			}
			var body map[string]any
			decodeJSON(t, stderr, &body)
			if body["error"].(map[string]any)["code"] != tt.code {
				t.Fatalf("stderr body = %#v", body)
			}
		})
	}
}

func TestConversationCommandsValidateArgsBeforeAPIRequests(t *testing.T) {
	var requestCount int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestCount++
		t.Fatalf("unexpected request path = %s", r.URL.Path)
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	cases := []struct {
		name string
		args []string
		code string
	}{
		{
			name: "missing project",
			args: []string{"conversations", "list", "--org", "acme", "--limit", "1", "--config", configPath, "--json"},
			code: "missing_project",
		},
		{
			name: "missing conversation",
			args: []string{"conversations", "messages", "--org", "acme", "--project", "support", "--limit", "1", "--config", configPath, "--json"},
			code: "missing_conversation",
		},
		{
			name: "invalid zero limit",
			args: []string{"conversations", "trace", "--org", "acme", "--project", "support", "--conversation", "task-1", "--limit", "0", "--config", configPath, "--json"},
			code: "invalid_limit",
		},
		{
			name: "missing delivery participant",
			args: []string{"conversations", "delivery", "--org", "acme", "--project", "support", "--conversation", "task-1", "--limit", "1", "--config", configPath, "--json"},
			code: "missing_participant",
		},
	}

	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			exitCode, stdout, stderr := runCLI(t, tt.args, nil)
			if exitCode != output.ExitUsage {
				t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
			}
			if stdout != "" {
				t.Fatalf("stdout = %q, want empty", stdout)
			}
			var body map[string]any
			decodeJSON(t, stderr, &body)
			if body["error"].(map[string]any)["code"] != tt.code {
				t.Fatalf("stderr body = %#v", body)
			}
		})
	}

	if requestCount != 0 {
		t.Fatalf("requestCount = %d, want 0", requestCount)
	}
}

func TestConversationCommandsUseBackendLimitContract(t *testing.T) {
	seenLimits := []string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cli/conversations" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		seenLimits = append(seenLimits, r.URL.Query().Get("limit"))
		writeOK(w, map[string]any{"mode": "conversations_list", "limit": 500, "conversations": []map[string]any{}})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	cases := [][]string{
		{"conversations", "list", "--org", "acme", "--project", "support", "--config", configPath, "--json"},
		{"conversations", "list", "--org", "acme", "--project", "support", "--limit", "1000", "--config", configPath, "--json"},
	}

	for _, args := range cases {
		exitCode, stdout, stderr := runCLI(t, args, nil)
		if exitCode != output.ExitOK {
			t.Fatalf("%v exit = %d stdout=%s stderr=%s", args, exitCode, stdout, stderr)
		}
	}

	want := []string{"100", "1000"}
	if strings.Join(seenLimits, ",") != strings.Join(want, ",") {
		t.Fatalf("seenLimits = %#v, want %#v", seenLimits, want)
	}
}

func TestRunnersListUsesProductAPIContract(t *testing.T) {
	var authHeader string
	var rawQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader = r.Header.Get("Authorization")
		rawQuery = r.URL.RawQuery
		if r.URL.Path != "/v1/orgs/acme/runners" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		writeOK(w, map[string]any{
			"runners": []map[string]any{
				{"id": "prov_1", "name": "online-primary", "status": "online"},
				{"id": "prov_2", "name": "offline-secondary", "status": "offline"},
				{"id": "prov_3", "name": "online-backup", "status": "online"},
			},
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"runners", "list", "--org", "acme", "--limit", "1", "--filter", "online", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if authHeader != "Bearer from-config-token" {
		t.Fatalf("Authorization = %q", authHeader)
	}
	for _, part := range []string{"limit=1", "filter=online"} {
		if !strings.Contains(rawQuery, part) {
			t.Fatalf("query %q missing %s", rawQuery, part)
		}
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if len(data["runners"].([]any)) != 1 {
		t.Fatalf("data = %#v", data)
	}
}

func TestRunnersInstallCommandRequiresExplicitConfirmation(t *testing.T) {
	requestCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestCount++
		writeOK(w, map[string]any{"mode": "runner_install_command"})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"runners", "install-command", "--org", "acme", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want empty", stdout)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	if body["error"].(map[string]any)["code"] != "confirm_mutating_required" {
		t.Fatalf("stderr body = %#v", body)
	}
	if requestCount != 0 {
		t.Fatalf("requestCount = %d, want 0", requestCount)
	}
}

func TestRunnersInstallCommandTextOutputKeepsExecutableOneTimeCommand(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/orgs/acme/runners/install-command" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if r.URL.Query().Get("runner") != "runner-stable-1" {
			t.Fatalf("runner query = %q", r.URL.Query().Get("runner"))
		}
		writeOK(w, map[string]any{
			"mode":        "runner_install_command",
			"action":      "install",
			"command":     "curl -fsSL \"https://bridge.example.test/install.sh?code=raw-install-code\" | sh",
			"release_id":  "2026.07",
			"org":         map[string]any{"slug": "acme"},
			"next_action": "Run the command on the target machine.",
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"runners", "install-command", "--org", "acme", "--runner", "runner-stable-1", "--confirm-mutating", "--config", configPath, "--output", "text"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, "code=raw-install-code") {
		t.Fatalf("stdout should contain executable one-time command: %s", stdout)
	}
}

func TestAPISuccessOutputRedactsSecretLikeFields(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/orgs/acme/runners/install-command" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		writeOK(w, map[string]any{
			"mode":            "runner_install_command",
			"command":         "curl -fsSL \"https://bridge.example.test/install.sh?code=raw-install-code&token=raw-token\" | sh",
			"app_secret":      "raw-app-secret",
			"connector_token": "raw-connector-token",
			"message_body":    "raw-message-body",
			"event":           map[string]any{"raw_message": "raw-nested-message"},
			"org":             map[string]any{"slug": "acme"},
			"next_action":     "Run the install command.",
		})
	}))
	defer server.Close()

	configPath := filepath.Join(t.TempDir(), "cli.json")
	if err := config.Persist(configPath, func(string) string { return "" }, config.Config{APIBaseURL: server.URL, Token: "from-config-token"}); err != nil {
		t.Fatalf("persist config: %v", err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{"runners", "install-command", "--org", "acme", "--confirm-mutating", "--config", configPath, "--json"}, nil)
	if exitCode != output.ExitOK {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	combined := stdout + stderr
	for _, secret := range []string{"raw-app-secret", "raw-connector-token", "raw-message-body", "raw-nested-message"} {
		if strings.Contains(combined, secret) {
			t.Fatalf("secret %q leaked in output: %s", secret, combined)
		}
	}
	for _, commandPart := range []string{"raw-install-code", "raw-token"} {
		if !strings.Contains(stdout, commandPart) {
			t.Fatalf("install command is not executable, missing %q: %s", commandPart, stdout)
		}
	}
	if !strings.Contains(stdout, "[REDACTED]") {
		t.Fatalf("stdout = %s", stdout)
	}
}

func runCLI(t *testing.T, args []string, env map[string]string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	envFn := func(key string) string {
		if env != nil {
			if value, ok := env[key]; ok {
				return value
			}
		}
		if key == "BFT_CLI_CONFIG" {
			return ""
		}
		return os.Getenv(key)
	}
	exitCode := Run(args, &stdout, &stderr, envFn)
	return exitCode, stdout.String(), stderr.String()
}

func writeOK(w http.ResponseWriter, data map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": data})
}

func deviceLoginTerminalStatusHandler(t *testing.T, status string) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/cli/auth/device":
			writeOK(w, map[string]any{
				"device_code":               "device-secret",
				"user_code":                 "ABCD1234",
				"verification_uri":          serverURL(r) + "/cli/device-login",
				"verification_uri_complete": serverURL(r) + "/cli/device-login/ABCD1234",
				"expires_at":                futureAuthExpiresAt(),
				"interval_seconds":          1,
			})
		case "/v1/cli/auth/device/poll":
			writeOK(w, map[string]any{
				"status":           status,
				"user_code":        "ABCD1234",
				"expires_at":       futureAuthExpiresAt(),
				"interval_seconds": 1,
			})
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}
}

func assertNoPersistedToken(t *testing.T, configPath string) {
	t.Helper()
	cfg, err := config.Load(configPath, func(string) string { return "" })
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Token != "" {
		t.Fatalf("config token should not be written: %#v", cfg)
	}
}

func serverURL(r *http.Request) string {
	return "http://" + r.Host
}

func futureAuthExpiresAt() string {
	return time.Now().Add(10 * time.Minute).UTC().Format(time.RFC3339Nano)
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    code,
			"message": message,
			"details": map[string]any{},
		},
	})
}

func decodeJSON(t *testing.T, raw string, target any) {
	t.Helper()
	if err := json.Unmarshal([]byte(raw), target); err != nil {
		t.Fatalf("invalid JSON %q: %v", raw, err)
	}
}
