package accountproxy

import (
	"strings"
	"testing"
	"time"
)

func TestQuotaNormalization(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		provider, body string
		remaining      float64
		period         string
	}{
		{"claude", `{"seven_day":{"utilization":75,"resets_at":"2026-09-15T00:00:00Z"}}`, 25, "week"},
		{"codex", `{"rate_limit":{"primary_window":{"used_percent":60,"reset_at":1789516800,"limit_window_seconds":604800}}}`, 40, "week"},
		{"codex", `{"rate_limit":{"primary_window":{"used_percent":20,"reset_at":1789516800,"limit_window_seconds":2592000}}}`, 80, "month"},
	} {
		s, err := decodeQuota(tc.provider, strings.NewReader(tc.body), now)
		if err != nil || len(s.Windows) != 1 || s.Windows[0].Remaining != tc.remaining || s.Windows[0].Period != tc.period {
			t.Fatalf("%s: %+v %v", tc.provider, s, err)
		}
	}
	if _, err := decodeQuota("claude", strings.NewReader(`{"seven_day":{"resets_at":"2026-09-15T00:00:00Z"}}`), now); err == nil {
		t.Fatal("missing utilization became full quota")
	}
}

func TestQuotaPlanMetadata(t *testing.T) {
	for _, plan := range []string{`"pro"`, `"free"`, `null`, `42`} {
		body := `{"plan_type":` + plan + `,"rate_limit":{"primary_window":{"used_percent":60,"reset_at":1789516800,"limit_window_seconds":604800}}}`
		snapshot, err := decodeQuota("codex", strings.NewReader(body), time.Now())
		if err != nil {
			t.Fatal(err)
		}
		expected := ""
		if plan == `"pro"` {
			expected = "pro"
		}
		if plan == `"free"` {
			expected = "free"
		}
		if snapshot.PlanType != expected {
			t.Fatalf("plan %s: got %q", plan, snapshot.PlanType)
		}
	}
}
