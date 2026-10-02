package accountproxy

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/tidwall/gjson"
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
		s.addWindow(100-used, reset, period, model)
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

// Invalid values are omitted. A missing value means unknown, never zero.
func (s *Snapshot) addWindow(remaining float64, reset time.Time, period, model string) {
	if math.IsNaN(remaining) || math.IsInf(remaining, 0) || remaining < 0 || remaining > 100 || reset.IsZero() {
		return
	}
	s.Windows = append(s.Windows, Window{remaining, reset, period, model})
}

func readQuotaBody(r io.Reader) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, 1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(b) > 1024*1024 || !gjson.ValidBytes(b) {
		return nil, errors.New("invalid quota response")
	}
	return b, nil
}

// Antigravity reports one remaining fraction per model. Each window applies
// only to requests for exactly that model ID. The response is proto3 JSON,
// which omits zero values: an exhausted model has a reset time and no
// fraction, so a missing fraction with a valid reset time means zero.
func decodeGeminiQuota(r io.Reader, now time.Time) (Snapshot, error) {
	b, err := readQuotaBody(r)
	if err != nil {
		return Snapshot{}, err
	}
	s := Snapshot{ObservedAt: now}
	gjson.GetBytes(b, "models").ForEach(func(id, model gjson.Result) bool {
		info := model.Get("quotaInfo")
		fraction := info.Get("remainingFraction")
		reset, err := time.Parse(time.RFC3339, info.Get("resetTime").String())
		if err == nil && id.String() != "" {
			switch {
			case fraction.Type == gjson.Number:
				s.addWindow(fraction.Float()*100, reset, "short", id.String())
			case !fraction.Exists():
				s.addWindow(0, reset, "short", id.String())
			}
		}
		return len(s.Windows) < 200
	})
	if len(s.Windows) == 0 {
		return Snapshot{}, errors.New("no supported quota windows")
	}
	return s, nil
}

// Grok Build reports included-credit use for the current weekly or monthly period.
func decodeGrokQuota(r io.Reader, now time.Time) (Snapshot, error) {
	b, err := readQuotaBody(r)
	if err != nil {
		return Snapshot{}, err
	}
	config := gjson.GetBytes(b, "config")
	used := config.Get("creditUsagePercent")
	reset, err := time.Parse(time.RFC3339, config.Get("currentPeriod.end").String())
	period := map[string]string{"USAGE_PERIOD_TYPE_WEEKLY": "week", "USAGE_PERIOD_TYPE_MONTHLY": "month"}[config.Get("currentPeriod.type").String()]
	s := Snapshot{ObservedAt: now, PlanType: strings.TrimSpace(gjson.GetBytes(b, "subscription_tier").String())}
	if used.Type == gjson.Number && err == nil && period != "" {
		s.addWindow(100-used.Float(), reset, period, "")
	}
	if len(s.Windows) == 0 {
		return Snapshot{}, errors.New("no supported quota windows")
	}
	return s, nil
}

// Kimi Code reports a weekly summary and shorter rolling limits. Counts can
// arrive as strings; "used" may be absent when "remaining" is present.
func decodeKimiQuota(r io.Reader, now time.Time) (Snapshot, error) {
	b, err := readQuotaBody(r)
	if err != nil {
		return Snapshot{}, err
	}
	s := Snapshot{ObservedAt: now}
	add := func(detail gjson.Result, period string) {
		limit, ok := quotaInt(detail.Get("limit"))
		if !ok || limit <= 0 {
			return
		}
		remaining, ok := quotaInt(detail.Get("remaining"))
		if used, usedOK := quotaInt(detail.Get("used")); usedOK {
			remaining, ok = limit-used, true
		}
		var reset time.Time
		for _, key := range []string{"resetTime", "reset_time", "resetAt", "reset_at"} {
			if t, err := time.Parse(time.RFC3339Nano, detail.Get(key).String()); err == nil {
				reset = t
				break
			}
		}
		if ok {
			s.addWindow(math.Max(0, math.Min(100, float64(remaining)*100/float64(limit))), reset, period, "")
		}
	}
	if usage := gjson.GetBytes(b, "usage"); usage.IsObject() {
		add(usage, "week")
	}
	gjson.GetBytes(b, "limits").ForEach(func(_, item gjson.Result) bool {
		detail := item.Get("detail")
		if !detail.IsObject() {
			detail = item
		}
		minutes, _ := quotaInt(item.Get("window.duration"))
		switch unit := item.Get("window.timeUnit").String(); {
		case strings.Contains(unit, "HOUR"):
			minutes *= 60
		case strings.Contains(unit, "DAY"):
			minutes *= 24 * 60
		case strings.Contains(unit, "MINUTE"):
		default:
			minutes = 0
		}
		period := "short"
		if minutes >= 6*24*60 && minutes <= 8*24*60 {
			period = "week"
		} else if minutes >= 28*24*60 {
			period = "month"
		}
		add(detail, period)
		return len(s.Windows) < 20
	})
	if len(s.Windows) == 0 {
		return Snapshot{}, errors.New("no supported quota windows")
	}
	return s, nil
}

func quotaInt(v gjson.Result) (int64, bool) {
	switch v.Type {
	case gjson.Number:
		return v.Int(), v.Float() == math.Trunc(v.Float())
	case gjson.String:
		n, err := strconv.ParseInt(strings.TrimSpace(v.String()), 10, 64)
		return n, err == nil
	}
	return 0, false
}
