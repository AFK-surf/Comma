//! A provider's answer about an account's allowance, as a Profile's quota: Salix's account-proxy fetches it for the
//! plans it holds, a station for the logins it has; both read the answer here.
//!
//! - claude: `api/oauth/usage` (`five_hour`, `seven_day`, `seven_day_<model>`: utilization and refill);
//! - codex: ChatGPT's `wham/usage` (`rate_limit.primary_window`/`secondary_window`) or the Codex app-server's
//!   `account/rateLimits/read` (`rateLimits.primary`/`secondary`), with the reset credits either reports;
//! - opencode-go: `zen/go/v1/usage` (`rolling`, `weekly`, `monthly`);
//! - gemini: Antigravity's `fetchAvailableModels` (a remaining fraction per model);
//! - grok: Grok Build's billing (`creditUsagePercent` of the current period);
//! - kimi-code: `coding/v1/usages` (a weekly summary and rolling limits, counts maybe strings);
//! - github-copilot: `copilot_internal/user` (`quota_snapshots`; premium requests are a window of their own).
//!
//! A value missing or malformed is unknown, never zero: its window is left out.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::{Quota, Window};

const DAY: i64 = 24 * 60;
const WEEK: i64 = 7 * DAY;
const MONTH: i64 = 30 * DAY;

/// Reset credits a plan has (ChatGPT): resets of a window it can spend.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ResetCredits {
    pub available_count: i64,
}

/// Credits of a plan beyond its windows (ChatGPT, as the app-server says).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Credits {
    pub has_credits: bool,
    pub unlimited: bool,
    #[serde(default)]
    pub balance: Option<String>,
}

/// A window's label, as the pages show it: hours for a short one, the week or the month, else days.
pub fn window_label(minutes: Option<i64>, fallback: &str) -> String {
    match minutes {
        Some(m) if m > 0 && m <= 6 * 60 => format!("{} 小时", (m as f64 / 60.0).round() as i64),
        Some(m) if (6 * DAY..=8 * DAY).contains(&m) => "每周".into(),
        Some(m) if m >= 27 * DAY => "每月".into(),
        Some(m) if m > 0 => format!("{} 天", (m as f64 / 60.0 / 24.0).round() as i64),
        _ => fallback.into(),
    }
}

/// A time as a provider gives it: epoch seconds or ms, or an RFC 3339 string (a date alone: its midnight UTC).
pub fn time_ms(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => {
            let f = n.as_f64()?;
            Some(if f > 1e12 { f as i64 } else { (f * 1000.0) as i64 })
        }
        Value::String(s) if !s.is_empty() => parse_rfc3339(s).or_else(|| parse_rfc3339(&format!("{s}T00:00:00Z"))),
        _ => None,
    }
}

/// RFC 3339 (`2026-10-07T11:00:00Z`, fractions and offsets allowed) as epoch ms.
fn parse_rfc3339(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || !(b[10] == b'T' || b[10] == b't' || b[10] == b' ') {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (
        num(0..4)?,
        num(5..7)?,
        num(8..10)?,
        num(11..13)?,
        num(14..16)?,
        num(17..19)?,
    );
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    let mut rest = &s[19..];
    let mut ms = 0;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits: String = frac.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() {
            return None;
        }
        ms = format!("{:0<3}", &digits[..digits.len().min(3)]).parse::<i64>().ok()?;
        rest = &frac[digits.len()..];
    }
    let offset = match rest {
        "Z" | "z" => 0,
        o if o.len() == 6 && (o.starts_with('+') || o.starts_with('-')) => {
            let sign = if o.starts_with('-') { -1 } else { 1 };
            sign * (o[1..3].parse::<i64>().ok()? * 60 + o[4..6].parse::<i64>().ok()?)
        }
        _ => return None,
    };
    // Days since the epoch (proleptic Gregorian).
    let (yy, mm) = if mo <= 2 { (y - 1, mo + 9) } else { (y, mo - 3) };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * mm + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 86_400 + h * 3600 + mi * 60 + se) - offset * 60) * 1000 + ms)
}

/// A number, or one in a string.
fn number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

/// An integer count, or one in a string.
fn count(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n
            .as_i64()
            .or_else(|| n.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64)),
        Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// A window of `used` percent (0–100, halves away from zero), when it is one.
fn window(
    used: f64,
    resets_at: Option<i64>,
    minutes: Option<i64>,
    fallback: &str,
    model: Option<&str>,
) -> Option<Window> {
    if !used.is_finite() || !(0.0..=100.0).contains(&used) {
        return None;
    }
    let model = model.filter(|m| !m.is_empty());
    // A window of one model says so: `每周 · Opus`.
    let base = window_label(minutes, fallback);
    let label = match model {
        Some(m) => {
            let mut c = m.chars();
            format!(
                "{base} · {}{}",
                c.next()
                    .map(|f| f.to_uppercase().collect::<String>())
                    .unwrap_or_default(),
                c.as_str()
            )
        }
        None => base,
    };
    Some(Window {
        label,
        used_percent: used.round(),
        resets_at,
        minutes,
        model: model.map(str::to_string),
    })
}

/// The minutes of a window `seconds` long, as a plan's: a week, a month, else short (five hours).
fn period_minutes(seconds: f64) -> i64 {
    if (6.0 * 86_400.0..=8.0 * 86_400.0).contains(&seconds) {
        WEEK
    } else if (28.0 * 86_400.0..=32.0 * 86_400.0).contains(&seconds) {
        MONTH
    } else if seconds > 0.0 {
        (seconds / 60.0).round() as i64
    } else {
        300
    }
}

/// The allowance a provider's answer says, read at `now` (ms since the epoch). `provider` is the plan's (the sources'
/// subscription ids, and opencode-go).
pub fn parse(provider: &str, body: &Value, now: i64) -> Quota {
    let mut quota = Quota {
        observed_at: Some(now),
        ..Default::default()
    };
    let windows = &mut quota.windows;
    match provider {
        "claude" => {
            if let Some(map) = body.as_object() {
                for (key, w) in map {
                    let model = if key == "five_hour" {
                        None
                    } else if let Some(rest) = key.strip_prefix("seven_day") {
                        Some(rest.trim_start_matches('_'))
                    } else {
                        continue;
                    };
                    let minutes = if key == "five_hour" { 300 } else { WEEK };
                    let (Some(used), resets) = (number(&w["utilization"]), time_ms(&w["resets_at"])) else {
                        continue;
                    };
                    windows.extend(window(used, resets, Some(minutes), "", model));
                }
            }
        }
        "codex" => {
            // The app-server's (camelCase, under rateLimits) or ChatGPT's own (snake_case, under rate_limit).
            let app = body.get("rateLimits").map_or(body, |v| v);
            for (key, fallback) in [("primary", 300), ("secondary", WEEK)] {
                if let Some(w) = app.get(key).filter(|w| w.is_object()) {
                    let minutes = w["windowDurationMins"].as_i64().filter(|m| *m > 0).unwrap_or(fallback);
                    if let Some(used) = number(&w["usedPercent"]) {
                        windows.extend(window(used, time_ms(&w["resetsAt"]), Some(minutes), "", None));
                    }
                }
            }
            for key in ["primary_window", "secondary_window"] {
                let w = &body["rate_limit"][key];
                let (Some(used), Some(reset)) = (number(&w["used_percent"]), time_ms(&w["reset_at"])) else {
                    continue;
                };
                let minutes = period_minutes(number(&w["limit_window_seconds"]).unwrap_or(0.0));
                windows.extend(window(used, Some(reset), Some(minutes), "", None));
            }
            if let Some(plan) = body["plan_type"].as_str().map(str::trim).filter(|p| !p.is_empty()) {
                quota.plan_type = Some(plan.into());
            }
            let resets = body
                .get("rate_limit_reset_credits")
                .or_else(|| body.get("rateLimitResetCredits"));
            // Only a whole, non-negative count: anything else is unknown.
            let whole = |v: &Value| v.as_i64().filter(|n| *n >= 0);
            if let Some(n) = resets.and_then(|r| whole(&r["available_count"]).or_else(|| whole(&r["availableCount"]))) {
                quota.reset_credits = Some(ResetCredits { available_count: n });
            }
            if let Some(c) = app.get("credits").filter(|c| c.is_object()) {
                quota.credits = Some(Credits {
                    has_credits: c["hasCredits"]
                        .as_bool()
                        .or(c["has_credits"].as_bool())
                        .unwrap_or(false),
                    unlimited: c["unlimited"].as_bool() == Some(true),
                    balance: match &c["balance"] {
                        Value::String(s) => Some(s.clone()),
                        Value::Number(n) => Some(n.to_string()),
                        _ => None,
                    },
                });
            }
        }
        "opencode-go" => {
            if let Some(usage) = body["usage"].as_object() {
                for (key, w) in usage {
                    let minutes = match key.as_str() {
                        "rolling" => Some(300),
                        "weekly" => Some(WEEK),
                        "monthly" => Some(MONTH),
                        _ => None,
                    };
                    let used = number(&w["percent"]).unwrap_or(0.0).clamp(0.0, 100.0);
                    windows.extend(window(used, time_ms(&w["resetsAt"]), minutes, key, None));
                }
            }
        }
        "gemini" => {
            // proto3 JSON leaves a zero out: a model with a refill and no fraction has none left.
            if let Some(models) = body["models"].as_object() {
                for (id, m) in models.iter().take(200) {
                    let info = &m["quotaInfo"];
                    let Some(reset) = time_ms(&info["resetTime"]) else {
                        continue;
                    };
                    let left = match &info["remainingFraction"] {
                        Value::Null => 0.0,
                        v => match number(v) {
                            Some(f) => f * 100.0,
                            None => continue,
                        },
                    };
                    windows.extend(window(100.0 - left, Some(reset), Some(300), "", Some(id)));
                }
            }
        }
        "grok" => {
            let config = &body["config"];
            let minutes = match config["currentPeriod"]["type"].as_str() {
                Some("USAGE_PERIOD_TYPE_WEEKLY") => Some(WEEK),
                Some("USAGE_PERIOD_TYPE_MONTHLY") => Some(MONTH),
                _ => None,
            };
            if let (Some(used), Some(reset), Some(minutes)) = (
                config["creditUsagePercent"].as_f64(),
                time_ms(&config["currentPeriod"]["end"]),
                minutes,
            ) {
                windows.extend(window(used, Some(reset), Some(minutes), "", None));
            }
            if let Some(tier) = body["subscription_tier"]
                .as_str()
                .map(str::trim)
                .filter(|t| !t.is_empty())
            {
                quota.plan_type = Some(tier.into());
            }
        }
        "kimi-code" => {
            let mut add = |detail: &Value, minutes: i64| {
                let Some(limit) = count(&detail["limit"]).filter(|l| *l > 0) else {
                    return;
                };
                let left = match count(&detail["used"]) {
                    Some(used) => Some(limit - used),
                    None => count(&detail["remaining"]),
                };
                let Some(left) = left else { return };
                let reset = ["resetTime", "reset_time", "resetAt", "reset_at"]
                    .iter()
                    .find_map(|k| time_ms(&detail[*k]));
                let used = 100.0 - (left as f64 * 100.0 / limit as f64).clamp(0.0, 100.0);
                windows.extend(window(used, reset, Some(minutes), "", None));
            };
            if body["usage"].is_object() {
                add(&body["usage"], WEEK);
            }
            for item in body["limits"].as_array().into_iter().flatten().take(20) {
                let detail = if item["detail"].is_object() {
                    &item["detail"]
                } else {
                    item
                };
                let duration = count(&item["window"]["duration"]).unwrap_or(0);
                let unit = item["window"]["timeUnit"].as_str().unwrap_or("");
                let minutes = if unit.contains("HOUR") {
                    duration * 60
                } else if unit.contains("DAY") {
                    duration * DAY
                } else if unit.contains("MINUTE") {
                    duration
                } else {
                    0
                };
                let minutes = if (6 * DAY..=8 * DAY).contains(&minutes) {
                    WEEK
                } else if minutes >= 28 * DAY {
                    MONTH
                } else if minutes > 0 {
                    minutes
                } else {
                    300
                };
                add(detail, minutes);
            }
        }
        "github-copilot" => {
            let reset = time_ms(&body["quota_reset_date_utc"]).or_else(|| time_ms(&body["quota_reset_date"]));
            if let Some(reset) = reset {
                for (key, model) in [("chat", None), ("premium_interactions", Some("premium"))] {
                    let q = &body["quota_snapshots"][key];
                    if !q.is_object() || q["unlimited"].as_bool() == Some(true) {
                        continue;
                    }
                    if let Some(left) = q["percent_remaining"].as_f64() {
                        windows.extend(window(100.0 - left, Some(reset), Some(MONTH), "", model));
                    }
                }
            }
            if let Some(plan) = body["copilot_plan"].as_str().map(str::trim).filter(|p| !p.is_empty()) {
                quota.plan_type = Some(plan.into());
            }
        }
        _ => {}
    }
    // A plan named at the top, by whichever provider names it there.
    if quota.plan_type.is_none()
        && let Some(plan) = body["plan_type"].as_str().map(str::trim).filter(|p| !p.is_empty())
    {
        quota.plan_type = Some(plan.into());
    }
    quota
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NOW: i64 = 1_791_370_800_000;

    #[test]
    fn times_are_read_however_they_come() {
        assert_eq!(time_ms(&json!("2026-10-07T11:00:00Z")), Some(1_791_370_800_000));
        assert_eq!(time_ms(&json!("2026-10-07T13:00:00.5+02:00")), Some(1_791_370_800_500));
        assert_eq!(time_ms(&json!(1_791_370_800)), Some(1_791_370_800_000));
        assert_eq!(time_ms(&json!("2026-10-07")), Some(1_791_331_200_000));
        assert_eq!(time_ms(&json!("soon")), None);
    }

    #[test]
    fn claude_weeks_of_one_model_are_that_models() {
        let q = parse(
            "claude",
            &json!({"five_hour": {"utilization": 12.5, "resets_at": "2026-10-07T15:00:00Z"},
                    "seven_day_opus": {"utilization": 100, "resets_at": "2026-10-10T00:00:00Z"},
                    "seven_day": {"utilization": "40", "resets_at": null},
                    "extra_usage": {"utilization": 1}}),
            NOW,
        );
        let mut got: Vec<_> = q
            .windows
            .iter()
            .map(|w| (w.label.as_str(), w.used_percent, w.model.as_deref()))
            .collect();
        got.sort_by(|a, b| a.0.cmp(b.0).then(a.2.cmp(&b.2)));
        assert_eq!(
            got,
            [
                ("5 小时", 13.0, None),
                ("每周", 40.0, None),
                ("每周 · Opus", 100.0, Some("opus"))
            ]
        );
    }

    #[test]
    fn codex_is_read_from_chatgpt_or_from_the_app_server() {
        let wham = parse(
            "codex",
            &json!({"plan_type": "pro", "rate_limit_reset_credits": {"available_count": 2},
                    "rate_limit": {"primary_window": {"used_percent": 30, "reset_at": 1_791_385_200, "limit_window_seconds": 18000},
                                   "secondary_window": {"used_percent": 60, "reset_at": 1_791_417_600, "limit_window_seconds": 604800}}}),
            NOW,
        );
        assert_eq!(
            wham.windows.iter().map(|w| w.minutes).collect::<Vec<_>>(),
            [Some(300), Some(WEEK)]
        );
        assert_eq!(
            (
                wham.plan_type.as_deref(),
                wham.reset_credits.as_ref().map(|r| r.available_count)
            ),
            (Some("pro"), Some(2))
        );
        let app = parse(
            "codex",
            &json!({"rateLimits": {"primary": {"usedPercent": 30, "windowDurationMins": 300, "resetsAt": 1_791_385_200},
                                   "credits": {"hasCredits": true, "unlimited": false, "balance": 5}},
                    "rateLimitResetCredits": {"availableCount": 1}}),
            NOW,
        );
        assert_eq!(app.windows[0].label, "5 小时");
        assert_eq!(
            app.credits,
            Some(Credits {
                has_credits: true,
                unlimited: false,
                balance: Some("5".into())
            })
        );
        assert_eq!(app.reset_credits, Some(ResetCredits { available_count: 1 }));
    }

    #[test]
    fn a_missing_or_malformed_value_is_unknown() {
        assert!(
            parse(
                "claude",
                &json!({"seven_day": {"resets_at": "2026-09-15T00:00:00Z"}}),
                NOW
            )
            .windows
            .is_empty()
        );
        let month = parse(
            "codex",
            &json!({"rate_limit": {"primary_window": {"used_percent": 20, "reset_at": 1_789_516_800, "limit_window_seconds": 2_592_000}}}),
            NOW,
        );
        assert_eq!(
            (month.windows[0].minutes, month.windows[0].used_percent),
            (Some(MONTH), 20.0)
        );
        for (plan, expected) in [(json!("pro"), Some("pro")), (json!(null), None), (json!(42), None)] {
            let q = parse(
                "codex",
                &json!({"plan_type": plan, "rate_limit": {"primary_window": {"used_percent": 60, "reset_at": 1_789_516_800}}}),
                NOW,
            );
            assert_eq!(q.plan_type.as_deref(), expected);
        }
        for (credits, expected) in [
            (json!(0), Some(0)),
            (json!(3), Some(3)),
            (json!(-1), None),
            (json!(1.5), None),
            (json!("2"), None),
        ] {
            let q = parse(
                "codex",
                &json!({"rate_limit_reset_credits": {"available_count": credits}, "rate_limit": {"primary_window": {"used_percent": 100, "reset_at": 1_789_516_800}}}),
                NOW,
            );
            assert_eq!(q.reset_credits.map(|r| r.available_count), expected);
        }
    }

    #[test]
    fn the_other_plans_say_theirs() {
        let gemini = parse(
            "gemini",
            &json!({"models": {"gemini-3-flash": {"quotaInfo": {"resetTime": "2026-10-07T15:00:00Z"}},
                                                        "gemini-3-pro": {"quotaInfo": {"remainingFraction": 0.25, "resetTime": "2026-10-07T15:00:00Z"}}}}),
            NOW,
        );
        assert_eq!(
            gemini
                .windows
                .iter()
                .map(|w| (w.used_percent, w.model.clone().unwrap()))
                .collect::<Vec<_>>(),
            [
                (100.0, "gemini-3-flash".to_string()),
                (75.0, "gemini-3-pro".to_string())
            ]
        );
        let grok = parse(
            "grok",
            &json!({"subscription_tier": "SuperGrok", "config": {"creditUsagePercent": 10, "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-10T00:00:00Z"}}}),
            NOW,
        );
        assert_eq!(
            (grok.windows[0].minutes, grok.plan_type.as_deref()),
            (Some(WEEK), Some("SuperGrok"))
        );
        let kimi = parse(
            "kimi-code",
            &json!({"usage": {"limit": "100", "remaining": "25", "resetTime": "2026-10-10T00:00:00Z"},
                                              "limits": [{"window": {"duration": 5, "timeUnit": "TIME_UNIT_HOUR"}, "detail": {"limit": 10, "used": 10}}]}),
            NOW,
        );
        assert_eq!(
            kimi.windows
                .iter()
                .map(|w| (w.minutes, w.used_percent))
                .collect::<Vec<_>>(),
            [(Some(WEEK), 75.0), (Some(300), 100.0)]
        );
        let copilot = parse(
            "github-copilot",
            &json!({"copilot_plan": "individual", "quota_reset_date": "2026-11-01",
                                                      "quota_snapshots": {"chat": {"unlimited": true}, "premium_interactions": {"percent_remaining": 40.0}}}),
            NOW,
        );
        assert_eq!(
            copilot
                .windows
                .iter()
                .map(|w| (w.used_percent, w.model.clone()))
                .collect::<Vec<_>>(),
            [(60.0, Some("premium".to_string()))]
        );
        let go = parse(
            "opencode-go",
            &json!({"usage": {"rolling": {"percent": 5, "resetsAt": "2026-10-07T15:00:00Z"}, "weekly": {"percent": 50}}}),
            NOW,
        );
        assert_eq!(
            go.windows.iter().map(|w| w.label.clone()).collect::<Vec<_>>(),
            ["5 小时", "每周"]
        );
        assert!(parse("nobody", &json!({}), NOW).windows.is_empty());
    }
}
