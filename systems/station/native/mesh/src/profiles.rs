//! The Profiles' logic (systems/profiles) for the station's TypeScript: JSON in, JSON out, as Salix's NIF takes it.

use comma_profiles::{Profile, Request, Runtime, model_key, rank, runtime_config, serves, sources, urgency, usable};
use napi::bindgen_prelude::*;
use napi_derive::napi;

fn json<T: serde::de::DeserializeOwned>(text: &str, what: &str) -> Result<T> {
    serde_json::from_str(text).map_err(|e| Error::from_reason(format!("{what}: {e}")))
}

fn text<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).expect("serializable")
}

/// The sources (sources.json), in the order they are offered.
#[napi(js_name = "profileSources")]
pub fn profile_sources() -> String {
    text(&sources())
}

/// The Profiles that serve a request, best first (their ids); throws when a strict request's model is served by none.
#[napi(js_name = "profileRank")]
pub fn profile_rank(profiles: String, request: String) -> Result<Vec<String>> {
    let profiles: Vec<Profile> = json(&profiles, "profiles")?;
    let request: Request = json(&request, "request")?;
    rank(&profiles, &request).map_err(Error::from_reason)
}

/// Whether a Profile can run a model now, and whether it serves it: `{usable, serves, urgency}`.
#[napi(js_name = "profileState")]
pub fn profile_state(profile: String, signals: String, model: Option<String>, now: f64) -> Result<String> {
    let profile: Profile = json(&profile, "profile")?;
    let signals = json(&signals, "signals")?;
    let now = now as i64;
    Ok(text(&serde_json::json!({
        "usable": usable(&profile, &signals, model.as_deref(), now),
        "serves": serves(&profile, model.as_deref()),
        "urgency": urgency(&profile, model.as_deref(), now),
    })))
}

/// The environment and Codex overrides for a Profile's processes of a runtime (`claude`, `codex`).
#[napi(js_name = "profileRuntimeConfig")]
pub fn profile_runtime_config(profile: String, runtime: String, key: String) -> Result<String> {
    let profile: Profile = json(&profile, "profile")?;
    let runtime: Runtime = json(&format!("\"{runtime}\""), "runtime")?;
    Ok(text(&runtime_config(&profile, runtime, &key)))
}

/// The runtimes a Profile can run.
#[napi(js_name = "profileRuntimes")]
pub fn profile_runtimes(profile: String) -> Result<Vec<String>> {
    let profile: Profile = json(&profile, "profile")?;
    Ok(comma_profiles::runtimes(&profile).into_iter().map(|r| text(&r).trim_matches('"').to_string()).collect())
}

/// What a model is, however it is spelled.
#[napi(js_name = "modelKey")]
pub fn model_key_js(spelled: String) -> String {
    model_key(&spelled)
}

/// A source's endpoints where it is (`endpoint`, `protocol` for one at the person's own address); null when unusable.
#[napi(js_name = "profileEndpoints")]
pub fn profile_endpoints(source: String, endpoint: Option<String>, protocol: Option<String>) -> Option<String> {
    let source = comma_profiles::find(&source)?;
    let protocol = protocol.as_deref().and_then(comma_profiles::Protocol::parse);
    comma_profiles::endpoints(source, endpoint.as_deref(), protocol).map(|at| text(&at))
}

/// An address as it is kept: trimmed, without a trailing slash; null unless it is an http(s) address.
#[napi(js_name = "cleanEndpoint")]
pub fn clean_endpoint(endpoint: String) -> Option<String> {
    comma_profiles::sources::clean_endpoint(&endpoint)
}

/// Codex's `-c` overrides for a Profile (its features off for any; its provider's for an API key's), in key order.
#[napi(js_name = "profileCodexOverrides")]
pub fn profile_codex_overrides(profile: String) -> Result<String> {
    let profile: Profile = json(&profile, "profile")?;
    Ok(text(&comma_profiles::codex_overrides(&profile)))
}

/// A provider's answer about an allowance (JSON) as a Profile's quota (JSON), read at `now` (ms since the epoch).
#[napi(js_name = "profileQuota")]
pub fn profile_quota(provider: String, body: String, now: f64) -> Result<String> {
    let body: serde_json::Value = json(&body, "body")?;
    Ok(text(&comma_profiles::quota::parse(&provider, &body, now as i64)))
}

/// A window's label, as the pages show it (quota.rs `window_label`).
#[napi(js_name = "profileWindowLabel")]
pub fn profile_window_label(minutes: Option<f64>, fallback: String) -> String {
    comma_profiles::quota::window_label(minutes.map(|m| m as i64), &fallback)
}
