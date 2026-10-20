//! Which Profiles serve a request, best first: Salix's AccountPool tries them in this order, a station starts a session
//! on the first.
//!
//! Only Profiles that serve the model qualify (not turned off for it; among the ones they list, when they list any). Of
//! those, one that is turned off, cannot sign in or was refused, ran into its allowance since it was read, or has a
//! window used up that has not refilled (a window of one model counts for that model only) is passed over. The rest
//! go in this order:
//! 1. one a provider asked to wait goes after the others, the soonest free first;
//! 2. one whose short window (a day or less) is nearly full goes last of those, as a session sent there would soon run
//!    into it;
//! 3. one whose long window (over a day) refills within a day, with some left, goes first, as what is left then is lost;
//! 4. then the one that has to spend fastest not to lose any (left × window length ÷ time to refill);
//! 5. then the one running fewer sessions, then the one picked least recently, then as given.
//!
//! A window whose refill is due counts as whole again, however long ago the allowance was read.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::model::{Profile, Status, Window, same_model};
use crate::runtime::{Runtime, runtimes};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// A short window this full puts its Profile last.
const CROWDED_PERCENT: f64 = 80.0;

/// What the caller knows of a Profile beyond the Profile itself.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Signals {
    /// Sessions running on it.
    #[serde(default)]
    pub load: u32,
    /// When it was last chosen (ms since the epoch; 0: never).
    #[serde(default)]
    pub last_picked: i64,
    /// A turn or request on it ran into its allowance since the allowance was read.
    #[serde(default)]
    pub spent: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Request {
    /// The model asked for; none: each Profile's own default.
    #[serde(default)]
    pub model: Option<String>,
    /// The id the provider is asked for it by, where it differs (a catalog model routed to a provider's own id): what a
    /// window of one model is matched against. None: `model`.
    #[serde(default)]
    pub provider_model: Option<String>,
    /// The runtime it runs in (a station's); none: any.
    #[serde(default)]
    pub runtime: Option<Runtime>,
    /// The model must be one a Profile serves. Otherwise (a binding made before models were chosen) Profiles that serve
    /// it come first, and without any every Profile serves.
    #[serde(default = "yes")]
    pub strict: bool,
    /// When nothing usable serves it, still give the ones that serve it (a station: the failure shows in the session).
    #[serde(default)]
    pub keep_unusable: bool,
    /// Now (ms since the epoch).
    pub now: i64,
    /// By Profile id.
    #[serde(default)]
    pub signals: BTreeMap<String, Signals>,
}

fn yes() -> bool {
    true
}

/// Whether a Profile serves a model (none: its own default).
pub fn serves(profile: &Profile, model: Option<&str>) -> bool {
    let Some(model) = model else { return true };
    if profile.disabled_models.iter().any(|m| same_model(m, model)) {
        return false;
    }
    profile
        .models
        .as_ref()
        .is_none_or(|listed| listed.iter().any(|m| same_model(m, model)))
}

/// Whether a window counts for this model: a window of one model counts for it only (Gemini names exact models; others a
/// family, as `gpt-5` for `gpt-5-codex`).
fn counts_for(window: &Window, source: &str, model: Option<&str>) -> bool {
    match (&window.model, model) {
        (None, _) => true,
        (Some(w), _) if w.is_empty() => true,
        (Some(_), None) => false,
        (Some(w), Some(m)) if source == "gemini" => w.eq_ignore_ascii_case(m),
        (Some(w), Some(m)) => m.to_lowercase().contains(&w.to_lowercase()),
    }
}

/// Whether a Profile can run this model now.
pub fn usable(profile: &Profile, signals: &Signals, model: Option<&str>, now: i64) -> bool {
    if profile.disabled || signals.spent || matches!(profile.status, Status::Login | Status::Failed) {
        return false;
    }
    let windows = profile.quota.as_ref().map(|q| q.windows.as_slice()).unwrap_or(&[]);
    !windows.iter().any(|w| {
        w.used_percent >= 100.0 && w.resets_at.is_none_or(|at| at > now) && counts_for(w, &profile.source, model)
    })
}

/// How a Profile's allowance ranks: whether its short windows are nearly full; whether a long window refills within a
/// day with some left; how fast it has to be spent not to lose any (1: evenly over the window; a window of unknown length
/// or refill counts as what it has left, evenly).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Urgency {
    pub crowded: bool,
    pub soon: bool,
    pub pace: f64,
}

/// The long windows (over a day) are what can be lost: the short ones refill again and again inside them, and only keep
/// a Profile from taking more now. One with no long window is weighed by the ones it has. Of several, the slowest
/// counts: the others cannot be spent faster than it lets. Only the windows that count for the model asked weigh (a
/// window of another model does not).
pub fn urgency(profile: &Profile, model: Option<&str>, now: i64) -> Urgency {
    // A window whose refill is due (an allowance read before it) is whole again: what it said of its use is past. Its
    // other words stay true however long ago they were read: when it refills, how long it is.
    let all: Vec<Window> = profile
        .quota
        .as_ref()
        .map(|q| {
            q.windows
                .iter()
                .filter(|w| counts_for(w, &profile.source, model))
                .map(|w| match w.resets_at {
                    Some(at) if at <= now => Window {
                        used_percent: 0.0,
                        resets_at: None,
                        ..w.clone()
                    },
                    _ => w.clone(),
                })
                .collect()
        })
        .unwrap_or_default();
    let used = if all.is_empty() {
        50.0
    } else {
        all.iter().map(|w| w.used_percent).fold(f64::MIN, f64::max)
    };
    let windows: Vec<&Window> = all.iter().filter(|w| w.minutes.is_some_and(|m| m > 0)).collect();
    let length = |w: &Window| w.minutes.unwrap_or(0) * 60_000;
    let long: Vec<&Window> = windows.iter().copied().filter(|w| length(w) > DAY_MS).collect();
    let short: Vec<&Window> = windows.iter().copied().filter(|w| length(w) <= DAY_MS).collect();
    let crowded = !long.is_empty() && short.iter().any(|w| w.used_percent >= CROWDED_PERCENT);
    let weighed: Vec<&Window> = (if long.is_empty() { &short } else { &long })
        .iter()
        .copied()
        .filter(|w| w.resets_at.is_some())
        .collect();
    if weighed.is_empty() {
        return Urgency {
            crowded,
            soon: false,
            pace: (100.0 - used) / 100.0,
        };
    }
    let (mut pace, mut soon) = (f64::MAX, false);
    for w in weighed {
        let left = (100.0 - w.used_percent).max(0.0) / 100.0;
        let len = length(w) as f64;
        let resets = w.resets_at.unwrap_or(now);
        let remaining = len.min(((resets - now).max(1)) as f64);
        let this = left * len / remaining;
        if this < pace {
            pace = this;
            soon = !long.is_empty() && left > 0.0 && resets > now && resets - now <= DAY_MS;
        }
    }
    Urgency { crowded, soon, pace }
}

/// The Profiles that serve a request, best first (their ids). An error when the request is strict and none serves its
/// model.
pub fn rank(profiles: &[Profile], request: &Request) -> Result<Vec<String>, String> {
    let model = request.model.as_deref();
    let none = Signals::default();
    let signals = |p: &Profile| request.signals.get(&p.id).unwrap_or(&none);
    let candidates: Vec<(usize, &Profile)> = profiles
        .iter()
        .enumerate()
        .filter(|(_, p)| request.runtime.is_none_or(|r| runtimes(p).contains(&r)))
        .collect();
    let mut serving: Vec<(usize, &Profile)> = candidates.iter().copied().filter(|(_, p)| serves(p, model)).collect();
    if serving.is_empty() {
        if request.strict {
            return Err(format!(
                "no profile has {} enabled; enable it on a profile first",
                model.unwrap_or("")
            ));
        }
        serving = candidates;
    }
    let asked = request.provider_model.as_deref().or(model);
    let fit: Vec<(usize, &Profile)> = serving
        .iter()
        .copied()
        .filter(|(_, p)| usable(p, signals(p), asked, request.now))
        .collect();
    let mut pool = if fit.is_empty() && request.keep_unusable {
        serving
    } else {
        fit
    };
    let now = request.now;
    let cooling = |p: &Profile| p.cooldown_until.filter(|&until| until > now);
    pool.sort_by(|(ia, a), (ib, b)| {
        let (ua, ub) = (urgency(a, asked, now), urgency(b, asked, now));
        let (sa, sb) = (signals(a), signals(b));
        (cooling(a).is_some().cmp(&cooling(b).is_some()))
            .then(cooling(a).cmp(&cooling(b)))
            .then(ua.crowded.cmp(&ub.crowded))
            .then(ub.soon.cmp(&ua.soon))
            .then(ub.pace.partial_cmp(&ua.pace).unwrap_or(std::cmp::Ordering::Equal))
            .then(sa.load.cmp(&sb.load))
            .then(sa.last_picked.cmp(&sb.last_picked))
            .then(ia.cmp(ib))
    });
    Ok(pool.into_iter().map(|(_, p)| p.id.clone()).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Credential, Quota};

    const NOW: i64 = 1_800_000_000_000;
    const HOUR: i64 = 3_600_000;

    fn profile(id: &str) -> Profile {
        serde_json::from_value(serde_json::json!({"id": id, "source": "claude", "credential": "subscription", "runtime": "claude", "status": "ok"})).unwrap()
    }

    fn quota(windows: Vec<(f64, i64, i64)>) -> Option<Quota> {
        Some(Quota {
            windows: windows
                .into_iter()
                .map(|(used, minutes, resets)| Window {
                    used_percent: used,
                    minutes: Some(minutes),
                    resets_at: Some(resets),
                    ..Default::default()
                })
                .collect(),
            observed_at: Some(NOW),
            ..Default::default()
        })
    }

    fn request(model: Option<&str>) -> Request {
        Request {
            model: model.map(str::to_string),
            strict: true,
            now: NOW,
            ..Default::default()
        }
    }

    #[test]
    fn what_is_lost_soonest_is_spent_first_and_a_nearly_full_short_window_waits() {
        let mut a = profile("a");
        a.quota = quota(vec![(20.0, 300, NOW + HOUR), (40.0, 7 * 24 * 60, NOW + 5 * 24 * HOUR)]);
        let mut b = profile("b");
        // A week that refills within a day, with half of it left.
        b.quota = quota(vec![(10.0, 300, NOW + HOUR), (50.0, 7 * 24 * 60, NOW + 12 * HOUR)]);
        let mut c = profile("c");
        c.quota = quota(vec![(85.0, 300, NOW + HOUR), (10.0, 7 * 24 * 60, NOW + 12 * HOUR)]);
        assert_eq!(rank(&[a, b, c], &request(None)).unwrap(), ["b", "a", "c"]);
    }

    #[test]
    fn a_used_up_window_passes_a_profile_over_until_it_refills_and_a_models_own_counts_for_it_alone() {
        let mut a = profile("a");
        a.quota = quota(vec![(100.0, 300, NOW + HOUR)]);
        let b = profile("b");
        assert_eq!(rank(&[a.clone(), b.clone()], &request(None)).unwrap(), ["b"]);
        a.quota = quota(vec![(100.0, 300, NOW - 1)]);
        assert_eq!(rank(&[a.clone(), b.clone()], &request(None)).unwrap().len(), 2);
        a.source = "gemini".into();
        a.quota = quota(vec![(100.0, 300, NOW + HOUR)]);
        a.quota.as_mut().unwrap().windows[0].model = Some("gemini-2.5-flash".into());
        assert_eq!(
            rank(&[a.clone()], &request(Some("gemini-2.5-flash-lite"))).unwrap(),
            ["a"]
        );
        assert!(rank(&[a], &request(Some("gemini-2.5-flash"))).unwrap().is_empty());
    }

    #[test]
    fn a_profile_asked_to_wait_goes_last_and_load_then_last_pick_decide_the_rest() {
        let mut a = profile("a");
        a.cooldown_until = Some(NOW + HOUR);
        let (b, c) = (profile("b"), profile("c"));
        let mut req = request(None);
        req.signals.insert(
            "b".into(),
            Signals {
                load: 2,
                ..Default::default()
            },
        );
        req.signals.insert(
            "c".into(),
            Signals {
                load: 1,
                last_picked: 5,
                ..Default::default()
            },
        );
        assert_eq!(rank(&[a, b, c], &req).unwrap(), ["c", "b", "a"]);
    }

    #[test]
    fn a_model_needs_a_profile_that_serves_it() {
        let mut a = profile("a");
        a.models = Some(vec!["claude-opus-5-5".into()]);
        let mut b = profile("b");
        b.disabled_models = vec!["anthropic/claude-opus-5-5".into()];
        let c = profile("c");
        assert_eq!(
            rank(&[a.clone(), b.clone(), c], &request(Some("claude-opus-5-5"))).unwrap(),
            ["a", "c"]
        );
        assert!(rank(&[b.clone()], &request(Some("claude-opus-5-5"))).is_err());
        let mut lenient = request(Some("claude-opus-5-5"));
        lenient.strict = false;
        assert_eq!(rank(&[b], &lenient).unwrap(), ["b"]);
    }

    #[test]
    fn nothing_usable_is_nothing_unless_the_caller_keeps_the_unusable() {
        let mut a = profile("a");
        a.status = Status::Login;
        assert!(rank(&[a.clone()], &request(None)).unwrap().is_empty());
        let mut keep = request(None);
        keep.keep_unusable = true;
        assert_eq!(rank(&[a], &keep).unwrap(), ["a"]);
    }

    #[test]
    fn a_runtime_takes_the_profiles_it_can_run() {
        let a = profile("a");
        let mut b = profile("b");
        b.source = "codex".into();
        b.runtime = Some(Runtime::Codex);
        b.credential = Credential::Subscription;
        let mut req = request(None);
        req.runtime = Some(Runtime::Codex);
        assert_eq!(rank(&[a, b], &req).unwrap(), ["b"]);
    }

    #[test]
    fn a_window_of_another_model_does_not_weigh() {
        let mut a = profile("a");
        a.source = "gemini".into();
        a.quota = quota(vec![(95.0, 300, NOW + HOUR), (10.0, 7 * 24 * 60, NOW + 5 * 24 * HOUR)]);
        a.quota.as_mut().unwrap().windows[0].model = Some("gemini-3-flash".into());
        assert!(!urgency(&a, Some("gemini-3-pro"), NOW).crowded);
        assert!(urgency(&a, Some("gemini-3-flash"), NOW).crowded);
    }

    #[test]
    fn a_window_whose_refill_is_due_is_whole_again() {
        let mut p = profile("p");
        p.quota = quota(vec![(90.0, 7 * 24 * 60, NOW - HOUR)]);
        p.quota.as_mut().unwrap().observed_at = Some(NOW - 3 * 24 * HOUR);
        let u = urgency(&p, None, NOW);
        assert_eq!((u.crowded, u.soon), (false, false));
        assert_eq!(u.pace, 1.0);
    }
}
