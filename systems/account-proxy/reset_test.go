package accountproxy

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestResetCreditsQuotaSummary(t *testing.T) {
	for _, tc := range []struct {
		metadata string
		known    bool
		count    int64
	}{
		{``, false, 0}, {`,"rate_limit_reset_credits":{"available_count":0}`, true, 0},
		{`,"rate_limit_reset_credits":{"available_count":3}`, true, 3},
		{`,"rate_limit_reset_credits":{"available_count":-1}`, false, 0},
		{`,"rate_limit_reset_credits":{"available_count":1.5}`, false, 0},
		{`,"rate_limit_reset_credits":{"available_count":"2"}`, false, 0},
	} {
		body := `{"rate_limit":{"primary_window":{"used_percent":100,"reset_at":1789516800}}` + tc.metadata + `}`
		snapshot, err := decodeQuota("codex", strings.NewReader(body), time.Now())
		if err != nil || (snapshot.ResetCredits != nil) != tc.known {
			t.Fatalf("%s: %+v %v", body, snapshot, err)
		}
		if tc.known && snapshot.ResetCredits.AvailableCount != tc.count {
			t.Fatal(snapshot.ResetCredits)
		}
	}
}

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
