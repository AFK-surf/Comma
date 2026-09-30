package accountproxy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestDeviceAuthorizationUsesProviderPKCEAndNormalCredentials(t *testing.T) {
	original := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = original })
	polls := 0
	http.DefaultTransport = refreshTransport(func(r *http.Request) (*http.Response, error) {
		status, body := 200, ""
		switch r.URL.Path {
		case "/api/accounts/deviceauth/usercode":
			body = `{"device_auth_id":"private-device-id","user_code":"ABCD-EFGH","interval":"5"}`
		case "/api/accounts/deviceauth/token":
			polls++
			var input map[string]string
			if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
				t.Fatal(err)
			}
			if input["device_auth_id"] != "private-device-id" || input["user_code"] != "ABCD-EFGH" {
				t.Fatal("lost device authorization context")
			}
			if polls == 1 {
				status, body = 403, `{}`
			} else {
				body = `{"authorization_code":"code","code_verifier":"verifier","code_challenge":"challenge"}`
			}
		case "/oauth/token":
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if r.Form.Get("code_verifier") != "verifier" || r.Form.Get("redirect_uri") != "https://auth.openai.com/deviceauth/callback" {
				t.Fatal("incorrect token exchange")
			}
			body = `{"access_token":"access","refresh_token":"refresh","id_token":"header.eyJlbWFpbCI6Im1lbWJlckBleGFtcGxlLmNvbSJ9.signature","expires_in":3600}`
		default:
			t.Fatalf("unexpected endpoint %s", r.URL.Path)
		}
		return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	call := func(op string, input any) map[string]any {
		t.Helper()
		data, _ := json.Marshal(input)
		var result map[string]any
		if err := execute(context.Background(), op, data, Credential{}, func(data []byte) error { return json.Unmarshal(data, &result) }); err != nil {
			t.Fatal(err)
		}
		return result
	}
	attempt := call("/oauth/device/begin", map[string]any{})
	if attempt["user_code"] != "ABCD-EFGH" || attempt["interval"] != float64(5) {
		t.Fatal(attempt)
	}
	if result := call("/oauth/device/poll", attempt); result["status"] != "pending" {
		t.Fatal(result)
	}
	result := call("/oauth/device/poll", attempt)
	credentials := result["credentials"].(map[string]any)
	if credentials["access_token"] != "access" || credentials["refresh_token"] != "refresh" || credentials["type"] != "codex" {
		t.Fatal("device credentials do not match normal Codex storage")
	}
}
