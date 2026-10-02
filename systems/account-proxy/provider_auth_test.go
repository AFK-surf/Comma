package accountproxy

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

type stubResponse struct {
	status int
	body   string
}

// stubProviders replaces the default transport with fixed responses by host
// and path. Each route returns its listed responses in order, then repeats the last one.
func stubProviders(t *testing.T, routes map[string][]stubResponse, seen func(*http.Request)) {
	t.Helper()
	original := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = original })
	calls := map[string]int{}
	http.DefaultTransport = refreshTransport(func(r *http.Request) (*http.Response, error) {
		key := r.URL.Host + r.URL.Path
		responses, ok := routes[key]
		if !ok {
			t.Errorf("unexpected request %s %s", r.Method, key)
			return nil, fmt.Errorf("unexpected request")
		}
		if seen != nil {
			seen(r)
		}
		response := responses[min(calls[key], len(responses)-1)]
		calls[key]++
		return &http.Response{StatusCode: response.status, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(response.body)), Request: r}, nil
	})
}

func call(t *testing.T, op string, input any) (map[string]any, error) {
	t.Helper()
	data, _ := json.Marshal(input)
	var result map[string]any
	// Executors with private transports honor the SDK's context transport hook.
	ctx := context.WithValue(context.Background(), "cliproxy.roundtripper", http.DefaultTransport)
	err := execute(ctx, op, data, Credential{}, func(data []byte) error { return json.Unmarshal(data, &result) })
	return result, err
}

func jwtWith(claims map[string]any) string {
	data, _ := json.Marshal(claims)
	return "header." + base64.RawURLEncoding.EncodeToString(data) + ".signature"
}

// Device sign-in keeps the provider's private context in the host attempt,
// reports pending and slow_down states, and returns normalizable credentials.
func TestDeviceSignInForNewProviders(t *testing.T) {
	expires := time.Now().Add(time.Hour).Unix()
	cases := []struct {
		provider string
		routes   map[string][]stubResponse
		check    func(*http.Request)
		email    string
	}{
		{"grok", map[string][]stubResponse{
			"auth.x.ai/.well-known/openid-configuration": {{200, `{"device_authorization_endpoint":"https://auth.x.ai/oauth2/device/code","token_endpoint":"https://auth.x.ai/oauth2/token"}`}},
			"auth.x.ai/oauth2/device/code":               {{200, `{"device_code":"private-device","user_code":"GROK-1","verification_uri_complete":"https://accounts.x.ai/device?code=GROK-1","interval":5,"expires_in":900}`}},
			"auth.x.ai/oauth2/token": {{400, `{"error":"authorization_pending"}`}, {400, `{"error":"slow_down"}`},
				{200, fmt.Sprintf(`{"access_token":"grok-access","refresh_token":"grok-refresh","id_token":%q,"expires_in":3600}`, jwtWith(map[string]any{"email": "grok@example.com", "sub": "user-1"}))}},
		}, nil, "grok@example.com"},
		{"kimi-code", map[string][]stubResponse{
			"auth.kimi.com/api/oauth/device_authorization": {{200, `{"device_code":"private-device","user_code":"KIMI-1","verification_uri_complete":"https://www.kimi.com/code/authorize_device?user_code=KIMI-1","interval":5,"expires_in":900}`}},
			"auth.kimi.com/api/oauth/token":                {{200, `{"error":"authorization_pending"}`}, {200, `{"error":"slow_down"}`}, {200, `{"access_token":"kimi-access","refresh_token":"kimi-refresh","token_type":"Bearer","expires_in":3600}`}},
		}, nil, ""},
		{"github-copilot", map[string][]stubResponse{
			"github.com/login/device/code":             {{200, `{"device_code":"private-device","user_code":"GH-1","verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}`}},
			"github.com/login/oauth/access_token":      {{200, `{"error":"authorization_pending"}`}, {200, `{"error":"slow_down","interval":10}`}, {200, `{"access_token":"github-token","token_type":"bearer"}`}},
			"api.github.com/copilot_internal/v2/token": {{200, fmt.Sprintf(`{"token":%q,"expires_at":%d}`, copilotToken, expires)}},
			"api.github.com/user":                      {{200, `{"id":42,"login":"octo","email":"octo@example.com"}`}},
		}, func(r *http.Request) {
			if r.URL.Path == "/copilot_internal/v2/token" && r.Header.Get("Authorization") != "Bearer github-token" {
				panic("Copilot token exchange did not use the GitHub token")
			}
		}, "id:github:42"},
	}
	for _, tc := range cases {
		t.Run(tc.provider, func(t *testing.T) {
			deviceIDs := map[string]bool{}
			stubProviders(t, tc.routes, func(r *http.Request) {
				if tc.provider == "kimi-code" {
					deviceIDs[r.Header.Get("X-Msh-Device-Id")] = true
				}
				if tc.check != nil {
					tc.check(r)
				}
			})
			attempt, err := call(t, "/oauth/device/begin", map[string]any{"provider": tc.provider})
			if err != nil {
				t.Fatal(err)
			}
			if attempt["provider"] != tc.provider || attempt["mode"] != "device" || attempt["device_auth_id"] != "private-device" || !strings.HasPrefix(attempt["url"].(string), "https://") || attempt["interval"] != float64(5) {
				t.Fatalf("attempt %+v", attempt)
			}
			if r, err := call(t, "/oauth/device/poll", attempt); err != nil || r["status"] != "pending" || r["slow_down"] != nil {
				t.Fatalf("first poll %+v %v", r, err)
			}
			// The Kimi SDK reports slow_down as pending; the host interval still applies.
			if r, err := call(t, "/oauth/device/poll", attempt); err != nil || r["status"] != "pending" || (tc.provider != "kimi-code" && r["slow_down"] != true) {
				t.Fatalf("slow_down poll %+v %v", r, err)
			}
			result, err := call(t, "/oauth/device/poll", attempt)
			if err != nil {
				t.Fatal(err)
			}
			if result["email"] != tc.email {
				t.Fatalf("email %v", result["email"])
			}
			normalized, err := call(t, "/normalize", map[string]any{"provider": tc.provider, "credentials": result["credentials"]})
			if err != nil {
				t.Fatal(err)
			}
			credentials := normalized["credentials"].(map[string]any)
			if credentials["access_token"] == "" || credentials["refresh_token"] == nil || credentials["expired"] == nil {
				t.Fatalf("credentials cannot be stored and refreshed: %+v", credentials)
			}
			if tc.provider == "kimi-code" && (len(deviceIDs) != 1 || credentials["device_id"] == nil) {
				t.Fatalf("Kimi device identity changed between requests: %v", deviceIDs)
			}
		})
	}
}

func TestGeminiCallbackSignInResolvesProject(t *testing.T) {
	stubProviders(t, map[string][]stubResponse{
		"oauth2.googleapis.com/token":                           {{200, `{"access_token":"gemini-access","refresh_token":"gemini-refresh","expires_in":3600,"token_type":"Bearer"}`}},
		"www.googleapis.com/oauth2/v2/userinfo":                 {{200, `{"email":"gemini@example.com"}`}},
		"cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": {{200, `{"cloudaicompanionProject":"project-1"}`}},
	}, func(r *http.Request) {
		if r.URL.Path == "/token" {
			_ = r.ParseForm()
			if r.Form.Get("code") != "browser-code" || r.Form.Get("redirect_uri") != "http://localhost:51121/oauth-callback" {
				panic("exchange lost the authorization code or redirect")
			}
		}
	})
	attempt, err := call(t, "/oauth/begin", map[string]any{"provider": "gemini", "state": "host-state"})
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(attempt["url"].(string))
	if attempt["provider"] != "gemini" || u.Host != "accounts.google.com" || u.Query().Get("state") != "host-state" {
		t.Fatalf("attempt %+v", attempt)
	}
	result, err := call(t, "/oauth/exchange", map[string]any{"attempt": attempt, "code": "browser-code"})
	if err != nil {
		t.Fatal(err)
	}
	credentials := result["credentials"].(map[string]any)
	if result["email"] != "gemini@example.com" || credentials["project_id"] != "project-1" || credentials["refresh_token"] != "gemini-refresh" {
		t.Fatalf("result %+v", result)
	}
	if _, err := call(t, "/oauth/begin", map[string]any{"provider": "grok", "state": "s"}); err == nil {
		t.Fatal("a device-only provider started a callback sign-in")
	}
}

// Expired credentials refresh through each provider's token endpoint before use.
func TestPrepareRefreshesNewProviders(t *testing.T) {
	expired := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	future := time.Now().Add(time.Hour).Unix()
	cases := []struct {
		provider string
		extra    map[string]any
		routes   map[string][]stubResponse
		access   string
	}{
		{"gemini", map[string]any{"project_id": "project-1"}, map[string][]stubResponse{
			"oauth2.googleapis.com/token": {{200, `{"access_token":"gemini-rotated","expires_in":3600}`}},
		}, "gemini-rotated"},
		{"grok", nil, map[string][]stubResponse{
			"auth.x.ai/.well-known/openid-configuration": {{200, `{"device_authorization_endpoint":"https://auth.x.ai/oauth2/device/code","token_endpoint":"https://auth.x.ai/oauth2/token"}`}},
			"auth.x.ai/oauth2/token":                     {{200, `{"access_token":"grok-rotated","refresh_token":"grok-refresh-2","expires_in":3600}`}},
		}, "grok-rotated"},
		{"kimi-code", map[string]any{"device_id": "device-1"}, map[string][]stubResponse{
			"auth.kimi.com/api/oauth/token": {{200, `{"access_token":"kimi-rotated","refresh_token":"kimi-refresh-2","expires_in":3600}`}},
		}, "kimi-rotated"},
		{"github-copilot", nil, map[string][]stubResponse{
			"api.github.com/copilot_internal/v2/token": {{200, fmt.Sprintf(`{"token":%q,"expires_at":%d}`, copilotToken, future)}},
		}, copilotToken},
	}
	for _, tc := range cases {
		t.Run(tc.provider, func(t *testing.T) {
			stubProviders(t, tc.routes, nil)
			credentials := map[string]any{"access_token": "old", "refresh_token": "refresh", "expired": expired}
			for k, v := range tc.extra {
				credentials[k] = v
			}
			result, err := call(t, "/prepare", map[string]any{"provider": tc.provider, "credentials": credentials})
			if err != nil {
				t.Fatal(err)
			}
			prepared := result["credentials"].(map[string]any)
			expiry, _ := time.Parse(time.RFC3339, fmt.Sprint(prepared["expired"]))
			if prepared["access_token"] != tc.access || time.Until(expiry) < time.Minute {
				t.Fatalf("prepared %+v", prepared)
			}
		})
	}
}

// Quota reads normalize each provider's report. A provider field that is
// missing stays unknown instead of becoming an exhausted window.
func TestQuotaForNewProviders(t *testing.T) {
	reset := time.Now().Add(48 * time.Hour).UTC().Format(time.RFC3339)
	cases := []struct {
		provider string
		route    string
		body     string
		want     []Window
	}{
		{"gemini", "cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
			fmt.Sprintf(`{"models":{"gemini-3.1-pro-low":{"quotaInfo":{"remainingFraction":0.25,"resetTime":%q}},"gemini-3-flash":{"quotaInfo":{"resetTime":%q}},"gemini-3-pro":{"quotaInfo":{"remainingFraction":"bad","resetTime":%q}},"gemini-3-flash":{"quotaInfo":{}}}}`, reset, reset, reset),
			// proto3 JSON omits a zero fraction: an exhausted model has only a reset time.
			[]Window{{Remaining: 25, Period: "short", Model: "gemini-3.1-pro-low"}, {Remaining: 0, Period: "short", Model: "gemini-3-flash"}}},
		{"grok", "cli-chat-proxy.grok.com/v1/billing",
			fmt.Sprintf(`{"config":{"creditUsagePercent":40,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":%q}}}`, reset),
			[]Window{{Remaining: 60, Period: "week"}}},
		{"kimi-code", "api.kimi.com/coding/v1/usages",
			fmt.Sprintf(`{"usage":{"limit":"100","remaining":"80","resetTime":%q},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","used":"50","resetTime":%q}}]}`, reset, reset),
			[]Window{{Remaining: 80, Period: "week"}, {Remaining: 0, Period: "short"}}},
		{"github-copilot", "api.github.com/copilot_internal/user",
			`{"copilot_plan":"individual","quota_reset_date":"2099-01-01","quota_snapshots":{"chat":{"unlimited":true},"premium_interactions":{"percent_remaining":12.5,"unlimited":false}}}`,
			[]Window{{Remaining: 12.5, Period: "month", Model: "premium"}}},
	}
	for _, tc := range cases {
		t.Run(tc.provider, func(t *testing.T) {
			stubProviders(t, map[string][]stubResponse{tc.route: {{200, tc.body}}}, func(r *http.Request) {
				if r.Header.Get("Authorization") == "" {
					panic("quota request has no credential")
				}
			})
			credentials := providerCredentials(tc.provider)
			credentials["refresh_token"] = "github-token"
			result, err := call(t, "/quota", map[string]any{"provider": tc.provider, "credentials": credentials})
			if err != nil {
				t.Fatal(err)
			}
			var got Snapshot
			data, _ := json.Marshal(result)
			_ = json.Unmarshal(data, &got)
			if len(got.Windows) != len(tc.want) {
				t.Fatalf("windows %+v", got.Windows)
			}
			for i, w := range tc.want {
				g := got.Windows[i]
				if g.Remaining != w.Remaining || g.Period != w.Period || g.Model != w.Model || g.Reset.IsZero() {
					t.Fatalf("window %d = %+v, want %+v", i, g, w)
				}
			}
		})
	}
}

// Copilot identity is the numeric GitHub id. A profile without one cannot be
// matched on reconnect, so sign-in fails rather than invent an identity.
func TestCopilotSignInRequiresGitHubID(t *testing.T) {
	expires := time.Now().Add(time.Hour).Unix()
	stubProviders(t, map[string][]stubResponse{
		"github.com/login/device/code":             {{200, `{"device_code":"private-device","user_code":"GH-1","verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}`}},
		"github.com/login/oauth/access_token":      {{200, `{"access_token":"github-token","token_type":"bearer"}`}},
		"api.github.com/copilot_internal/v2/token": {{200, fmt.Sprintf(`{"token":%q,"expires_at":%d}`, copilotToken, expires)}},
		"api.github.com/user":                      {{200, `{"login":"octo","email":"octo@example.com"}`}},
	}, nil)
	attempt, err := call(t, "/oauth/device/begin", map[string]any{"provider": "github-copilot"})
	if err != nil {
		t.Fatal(err)
	}
	if result, err := call(t, "/oauth/device/poll", attempt); err == nil && result["status"] != "error" {
		t.Fatalf("sign-in without a GitHub id succeeded: %+v", result)
	}
}

// An imported Copilot credential is matched by the same GitHub id as a sign-in.
func TestCopilotImportUsesGitHubID(t *testing.T) {
	credentials := map[string]any{"access_token": copilotToken, "refresh_token": "github-token", "email": "someone@example.com"}

	stubProviders(t, map[string][]stubResponse{
		"api.github.com/user": {{200, `{"id":7,"login":"octo","email":"octo@example.com"}`}},
	}, func(r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer github-token" {
			panic("identity lookup did not use the GitHub token")
		}
	})
	result, err := call(t, "/normalize", map[string]any{"provider": "github-copilot", "credentials": credentials})
	if err != nil || result["email"] != "id:github:7" {
		t.Fatalf("import identity %+v %v", result, err)
	}

	stubProviders(t, map[string][]stubResponse{"api.github.com/user": {{200, `{"login":"octo"}`}}}, nil)
	if _, err := call(t, "/normalize", map[string]any{"provider": "github-copilot", "credentials": credentials}); err == nil {
		t.Fatal("an import without a GitHub id succeeded")
	}
}
