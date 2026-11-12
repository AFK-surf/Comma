package accountproxy

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestResetUsesSDKAndStableRequestID(t *testing.T) {
	for _, outcome := range []string{"reset", "already_redeemed", "no_credit", "nothing_to_reset"} {
		t.Run(outcome, func(t *testing.T) {
			calls := 0
			call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != "POST" || r.URL.Path != "/backend-api/wham/rate-limit-reset-credits/consume" || r.Header.Get("Authorization") != "Bearer synthetic-token" || r.Header.Get("Chatgpt-Account-Id") != "selected-account" {
					t.Errorf("incorrect authenticated reset request")
				}
				var body map[string]string
				if json.NewDecoder(r.Body).Decode(&body) != nil || body["redeem_request_id"] != "same-logical-request-123" || len(body) != 1 {
					t.Errorf("incorrect reset body: %v", body)
				}
				fmt.Fprintf(w, `{"code":%q,"windows_reset":2}`, outcome)
			}))
			body := `{"provider":"codex","credentials":{"access_token":"synthetic-token","account_id":"selected-account"},"redeem_request_id":"same-logical-request-123"}`
			for i := 0; i < 2; i++ {
				got := call("/quota/reset", body)
				if got.Code != 200 || !strings.Contains(got.Body.String(), `"code":"`+outcome+`"`) {
					t.Fatalf("%d %s", got.Code, got.Body)
				}
			}
			if calls != 2 {
				t.Fatal(calls)
			}
		})
	}
}

func TestResetRejectsUnsupportedAndMalformedRequests(t *testing.T) {
	call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("must not call upstream") }))
	for _, body := range []string{
		`{"provider":"claude","credentials":{"access_token":"fake"},"redeem_request_id":"same-logical-request-123"}`,
		`{"provider":"claude","client_version":"2.1.308","credentials":{"access_token":"fake"},"redeem_request_id":"same-logical-request-123","kind":"credit"}`,
		`{"provider":"gemini","client_version":"2.1.308","credentials":{"access_token":"fake"},"redeem_request_id":"same-logical-request-123"}`,
		`{"provider":"codex","credentials":{"access_token":"fake"},"redeem_request_id":""}`,
	} {
		if got := call("/quota/reset", body); got.Code != 400 {
			t.Fatalf("%d %s", got.Code, got.Body)
		}
	}
}

func TestResetDoesNotTreatUnknownResponsesAsSuccess(t *testing.T) {
	for _, response := range []string{`{}`, `{"code":"unknown"}`, `{"code":"reset","windows_reset":-1}`, strings.Repeat("x", 65537)} {
		call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, response) }))
		got := call("/quota/reset", `{"provider":"codex","credentials":{"access_token":"fake"},"redeem_request_id":"same-logical-request-123"}`)
		if got.Code != 502 {
			t.Fatalf("%d %s", got.Code, got.Body)
		}
	}
}

func TestClaudeResetUsesTheChosenKindAsClaudeCode(t *testing.T) {
	usage := `{"juniper_tide":{"eligible":true,"arm":"reset","available":true},
		"cedar_ember":{"eligible":true,"next_grant_id":"full-2","grants":[
			{"id":"fable-1","type":"fable","resets_left":1,"usable_now":true,"ends_at":"2026-12-01T00:00:00Z"},
			{"id":"full-1","clears":["five_hour","seven_day"],"resets_left":1,"usable_now":true,"ends_at":"2026-11-20T00:00:00Z"},
			{"id":"full-2","type":"full","resets_left":2,"usable_now":true,"ends_at":"2026-11-25T00:00:00Z"},
			{"id":"weekly-1","clears":["seven_day"],"resets_left":1,"usable_now":false}]}}`
	sum := sha256.Sum256([]byte("same-logical-request-123"))
	for _, tc := range []struct{ kind, claim, code string }{
		{"", `{"program":"juniper_tide"}`, "reset"},
		{"session", `{"program":"juniper_tide"}`, "reset"},
		{"model", `{"grant_id":"fable-1","program":"cedar_ember","request_id":"` + hex.EncodeToString(sum[:]) + `"}`, "reset"},
		{"full", `{"grant_id":"full-2","program":"cedar_ember","request_id":"` + hex.EncodeToString(sum[:]) + `"}`, "already_redeemed"},
		{"weekly", ``, "nothing_to_reset"},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			var claimed string
			call, _ := fixture(t, "claude", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("User-Agent") != "claude-cli/2.1.308 (external, cli)" || r.Header.Get("anthropic-beta") != "oauth-2025-04-20" {
					t.Errorf("not Claude Code's headers: %v", r.Header)
				}
				switch {
				case r.Method == "GET" && r.URL.Path == "/api/oauth/usage" && r.URL.Query().Get("at_wall") == "1":
					fmt.Fprint(w, usage)
				case r.Method == "GET" && r.URL.Path == "/api/oauth/profile":
					fmt.Fprint(w, `{"organization":{"uuid":"org-1"}}`)
				case r.Method == "POST" && r.URL.Path == "/api/organizations/org-1/reset_rate_limits":
					data, _ := io.ReadAll(r.Body)
					claimed = string(data)
					if tc.code == "already_redeemed" {
						fmt.Fprint(w, `{"result":"already_used"}`)
					} else {
						fmt.Fprint(w, `{"result":"reset"}`)
					}
				default:
					t.Errorf("unexpected %s %s", r.Method, r.URL)
				}
			}))
			got := call("/quota/reset", `{"provider":"claude","client_version":"2.1.308","credentials":{"access_token":"fake"},"redeem_request_id":"same-logical-request-123","kind":"`+tc.kind+`"}`)
			if got.Code != 200 || !strings.Contains(got.Body.String(), `"code":"`+tc.code+`"`) || claimed != tc.claim {
				t.Fatalf("%d %s claimed %s", got.Code, got.Body, claimed)
			}
		})
	}
}

func TestClaudeResetRefusedForNowIsUnavailable(t *testing.T) {
	for _, answer := range []string{`{"result":"cooldown"}`, `{"result":"ineligible"}`, ``} {
		call, _ := fixture(t, "claude", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/api/oauth/usage":
				fmt.Fprint(w, `{"juniper_tide":{"eligible":true,"arm":"reset","available":true}}`)
			case "/api/oauth/profile":
				fmt.Fprint(w, `{"organization":{"uuid":"org-1"}}`)
			default:
				if answer == "" {
					w.WriteHeader(http.StatusTooManyRequests)
					return
				}
				fmt.Fprint(w, answer)
			}
		}))
		got := call("/quota/reset", `{"provider":"claude","client_version":"2.1.308","credentials":{"access_token":"fake"},"redeem_request_id":"same-logical-request-123"}`)
		if got.Code != 200 || !strings.Contains(got.Body.String(), `"code":"unavailable"`) {
			t.Fatalf("%q: %d %s", answer, got.Code, got.Body)
		}
	}
}

func TestClaudeQuotaAsksAsClaudeCodeAndSaysThePlan(t *testing.T) {
	for _, profile := range []int{200, 500} {
		call, _ := fixture(t, "claude", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("User-Agent") != "claude-cli/2.1.308 (external, cli)" {
				t.Errorf("not Claude Code's User-Agent: %q", r.Header.Get("User-Agent"))
			}
			switch r.URL.Path {
			case "/api/oauth/usage":
				if r.URL.Query().Get("at_wall") != "1" || r.URL.Query().Get("skip_spend") != "1" {
					t.Errorf("usage asked without the resets: %s", r.URL)
				}
				fmt.Fprint(w, `{"seven_day":{"utilization":10}}`)
			case "/api/oauth/profile":
				w.WriteHeader(profile)
				fmt.Fprint(w, `{"account":{"email":"a@b"},"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}`)
			}
		}))
		got := call("/quota", `{"provider":"claude","client_version":"2.1.308","credentials":{"access_token":"fake"}}`)
		var answer struct {
			Body map[string]json.RawMessage `json:"body"`
		}
		if got.Code != 200 || json.Unmarshal(got.Body.Bytes(), &answer) != nil || answer.Body["seven_day"] == nil {
			t.Fatalf("%d %s", got.Code, got.Body)
		}
		want := `{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}`
		if profile != 200 {
			want = ""
		}
		if string(answer.Body["plan"]) != want || strings.Contains(got.Body.String(), "a@b") {
			t.Fatalf("plan %s", answer.Body["plan"])
		}
	}
}
