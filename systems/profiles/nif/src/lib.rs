//! SalixAgent.Profiles.Native: the Profiles' logic (systems/profiles) for Salix, JSON in and out. Each call is a few
//! microseconds of pure work over a bounded list (a tenant's candidates), so it runs on the calling scheduler.

use comma_profiles::{Profile, Request, Runtime, Signals, model_key, rank, runtime_config, sources, usable};

fn json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T, String> {
    serde_json::from_str(text).map_err(|e| e.to_string())
}

/// The sources (sources.json), as JSON.
#[rustler::nif]
fn sources_json() -> String {
    serde_json::to_string(sources()).expect("serializable")
}

/// The Profiles that serve a request, best first: `{:ok, ids}`, or `{:error, reason}` (a strict request's model served
/// by none, or JSON that is not a Profile list and a request).
#[rustler::nif]
fn rank_json(profiles: String, request: String) -> Result<Vec<String>, String> {
    let profiles: Vec<Profile> = json(&profiles)?;
    let request: Request = json(&request)?;
    rank(&profiles, &request)
}

/// The environment and Codex overrides for a Profile's processes of a runtime ("claude", "codex"), as JSON.
#[rustler::nif]
fn runtime_config_json(profile: String, runtime: String, key: String) -> Result<String, String> {
    let profile: Profile = json(&profile)?;
    let runtime: Runtime = json(&format!("\"{runtime}\""))?;
    Ok(serde_json::to_string(&runtime_config(&profile, runtime, &key)).expect("serializable"))
}

/// Whether a Profile can run a model (`""`: any) now (ms since the epoch).
#[rustler::nif]
fn usable_json(profile: String, model: String, now: i64) -> Result<bool, String> {
    let profile: Profile = json(&profile)?;
    let model = (!model.is_empty()).then_some(model.as_str());
    Ok(usable(&profile, &Signals::default(), model, now))
}

/// A provider's answer about an allowance (JSON) as a Profile's quota (JSON), read at `now` (ms since the epoch).
#[rustler::nif]
fn quota_json(provider: String, body: String, now: i64) -> Result<String, String> {
    let body: serde_json::Value = json(&body)?;
    Ok(serde_json::to_string(&comma_profiles::quota::parse(&provider, &body, now)).expect("serializable"))
}

/// What a model is, however it is spelled.
#[rustler::nif]
fn model_key_of(spelled: String) -> String {
    model_key(&spelled)
}

rustler::init!("Elixir.SalixAgent.Profiles.Native");
