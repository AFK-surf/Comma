package accountproxy

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type refreshTransport func(*http.Request) (*http.Response, error)

func (f refreshTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestImportedCodexCredentialsRefreshBeforeUse(t *testing.T) {
	jwt := func(exp int64) string {
		return "header." + base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d,"email":"test@example.com"}`, exp))) + ".signature"
	}
	for _, tc := range []struct {
		name, token string
		refreshes   int
		force       bool
	}{
		{"expired native token", jwt(time.Now().Add(-time.Hour).Unix()), 1, false},
		{"current native token", jwt(time.Now().Add(time.Hour).Unix()), 0, false},
		{"unknown expiry", "opaque", 1, false},
		{"rejected current token", jwt(time.Now().Add(time.Hour).Unix()), 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := http.DefaultTransport
			calls := 0
			http.DefaultTransport = refreshTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host != "auth.openai.com" || r.URL.Path != "/oauth/token" {
					t.Fatalf("unexpected request: %s", r.URL)
				}
				calls++
				body, _ := json.Marshal(map[string]any{"access_token": "rotated-access", "refresh_token": "rotated-refresh", "id_token": jwt(time.Now().Add(time.Hour).Unix()), "expires_in": 3600})
				return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
			})
			defer func() { http.DefaultTransport = original }()
			native, _ := json.Marshal(Credential{Provider: "codex", Credentials: map[string]any{"tokens": map[string]any{"access_token": tc.token, "refresh_token": "refresh-" + tc.name}}})
			var normalized, prepared Credential
			emit := func(data []byte) error { return json.Unmarshal(data, &normalized) }
			if err := execute(context.Background(), "/normalize", native, Credential{}, emit); err != nil {
				t.Fatal(err)
			}
			normalized.Provider = "codex"
			normalized.ForceRefresh = tc.force
			payload, _ := json.Marshal(normalized)
			if err := execute(context.Background(), "/prepare", payload, Credential{}, func(data []byte) error { return json.Unmarshal(data, &prepared) }); err != nil {
				t.Fatal(err)
			}
			if calls != tc.refreshes {
				t.Fatalf("refresh calls=%d, want %d", calls, tc.refreshes)
			}
			if tc.refreshes > 0 && prepared.Credentials["access_token"] != "rotated-access" {
				t.Fatal("expired credential was not replaced")
			}
			expiry, _ := prepared.Credentials["expired"].(string)
			if _, err := time.Parse(time.RFC3339, expiry); err != nil {
				t.Fatal("prepared credential has no usable expiry")
			}
		})
	}
}
