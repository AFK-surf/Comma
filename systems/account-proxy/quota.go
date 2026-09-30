package accountproxy

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"strings"
	"time"
)

func decodeQuota(provider string, r io.Reader, now time.Time) (Snapshot, error) {
	var data map[string]any
	b, err := io.ReadAll(io.LimitReader(r, 1024*1024+1))
	if err != nil {
		return Snapshot{}, err
	}
	if len(b) > 1024*1024 {
		return Snapshot{}, errors.New("quota response too large")
	}
	if err = json.Unmarshal(b, &data); err != nil {
		return Snapshot{}, err
	}
	s := Snapshot{ObservedAt: now}
	add := func(used float64, reset time.Time, period, model string) {
		if math.IsNaN(used) || math.IsInf(used, 0) || used < 0 || used > 100 || reset.IsZero() {
			return
		}
		s.Windows = append(s.Windows, Window{100 - used, reset, period, model})
	}
	if provider == "claude" {
		for k, v := range data {
			if k != "five_hour" && !strings.HasPrefix(k, "seven_day") {
				continue
			}
			w, ok := v.(map[string]any)
			if !ok {
				continue
			}
			used, ok := w["utilization"].(float64)
			if !ok {
				continue
			}
			raw, _ := w["resets_at"].(string)
			reset, err := time.Parse(time.RFC3339, raw)
			if err != nil {
				continue
			}
			period, model := "short", ""
			if strings.HasPrefix(k, "seven_day") {
				period = "week"
				model = strings.TrimPrefix(k, "seven_day")
				model = strings.TrimPrefix(model, "_")
			}
			add(used, reset, period, model)
		}
	} else {
		if plan, ok := data["plan_type"].(string); ok {
			s.PlanType = strings.TrimSpace(plan)
		}
		// Missing or malformed optional metadata must not become a reported zero.
		if credits, ok := data["rate_limit_reset_credits"].(map[string]any); ok {
			if count, ok := credits["available_count"].(float64); ok && count >= 0 && count < 1<<53 && math.Trunc(count) == count {
				s.ResetCredits = &ResetCredits{AvailableCount: int64(count)}
			}
		}
		limits, _ := data["rate_limit"].(map[string]any)
		for _, key := range []string{"primary_window", "secondary_window"} {
			w, ok := limits[key].(map[string]any)
			if !ok {
				continue
			}
			used, ok := w["used_percent"].(float64)
			if !ok {
				continue
			}
			stamp, ok := w["reset_at"].(float64)
			if !ok {
				continue
			}
			seconds, _ := w["limit_window_seconds"].(float64)
			period := "short"
			if seconds >= 6*24*3600 && seconds <= 8*24*3600 {
				period = "week"
			} else if seconds >= 28*24*3600 && seconds <= 32*24*3600 {
				period = "month"
			}
			add(used, time.Unix(int64(stamp), 0), period, "")
		}
	}
	if len(s.Windows) == 0 {
		return Snapshot{}, errors.New("no supported quota windows")
	}
	return s, nil
}
