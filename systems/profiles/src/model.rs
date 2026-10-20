//! A Profile: an account a request or a runtime runs on. Salix keeps its Profiles in the AccountPool (their credentials
//! sealed), a station in its config (its own logins in the Profiles' homes); both hand this structure to the pool and
//! the runtimes.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::runtime::Runtime;
use crate::sources::{Auth, Protocol};

/// How the account signs in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Credential {
    /// A subscription's sign-in (OAuth); its source names the plan.
    Subscription,
    /// A key for an API source.
    ApiKey,
    /// The machine's own login of a runtime, used where it is (a station only).
    Machine,
    /// Only the variables the Profile sets (a station only).
    Env,
}

/// Whether the account works, as its last check or sign-in says.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Ok,
    /// Needs a sign-in (never signed in, or the sign-in ran out).
    Login,
    /// The key or the sign-in was refused.
    Failed,
    #[default]
    Unknown,
}

/// One window of an allowance: how much of it is used and when it refills.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Window {
    #[serde(default)]
    pub label: String,
    pub used_percent: f64,
    /// When it refills (ms since the epoch), where known.
    #[serde(default)]
    pub resets_at: Option<i64>,
    /// Its length, where known: a long one (over a day) is what can be lost.
    #[serde(default)]
    pub minutes: Option<i64>,
    /// A window of one model only (a provider that limits each model apart).
    #[serde(default)]
    pub model: Option<String>,
}

/// A Profile's allowance as its provider last said it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Quota {
    #[serde(default)]
    pub windows: Vec<Window>,
    /// When it was read (ms since the epoch).
    #[serde(default)]
    pub observed_at: Option<i64>,
    /// The plan the provider says the account is on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_credits: Option<crate::quota::ResetCredits>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credits: Option<crate::quota::Credits>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// The source it connects to (sources.json).
    pub source: String,
    pub credential: Credential,
    /// The runtime a subscription, machine or variables-only Profile is for (an API key's follow from its source).
    #[serde(default)]
    pub runtime: Option<Runtime>,
    /// The person's address, for a source that needs one.
    #[serde(default)]
    pub endpoint: Option<String>,
    /// The protocol chosen at that address.
    #[serde(default)]
    pub protocol: Option<Protocol>,
    /// How the key is given where the person chose it (a custom address); none: as its source takes it.
    #[serde(default)]
    pub auth: Option<Auth>,
    /// The models it serves, where it says (a station's chosen ones, a custom endpoint's); none: whatever its source has.
    #[serde(default)]
    pub models: Option<Vec<String>>,
    /// What it says of models it lists that the catalog does not know, by model id: an endpoint's own models have no
    /// catalog entry to tell their context, output and inputs.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub model_info: BTreeMap<String, ModelInfo>,
    /// The models its owner turned off.
    #[serde(default)]
    pub disabled_models: Vec<String>,
    /// Its default model.
    #[serde(default)]
    pub model: Option<String>,
    /// Variables of its own for its runtimes (they win over what its access sets).
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default)]
    pub status: Status,
    #[serde(default)]
    pub quota: Option<Quota>,
    /// Passed over until then (ms since the epoch): a provider asked to wait.
    #[serde(default)]
    pub cooldown_until: Option<i64>,
}

/// A listed model's limits and inputs, where its Profile says them; none: the defaults of a model the catalog does not
/// know.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub images: Option<bool>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub efforts: Vec<String>,
}

/// What a model is, however it is spelled: lower case, without its provider's prefix, region, version stamp or date; a
/// `[1m]` context stays.
pub fn model_key(spelled: &str) -> String {
    let id = spelled.trim().to_lowercase();
    let (base, context) = match id.find('[') {
        Some(at) => (id[..at].to_string(), id[at..].to_string()),
        None => (id.clone(), String::new()),
    };
    // OpenRouter's and other routers' `vendor/model`; Vertex's `model@date`.
    let mut m = base.rsplit('/').next().unwrap_or("").to_string();
    m = m.split('@').next().unwrap_or("").to_string();
    // Bedrock's `us.anthropic.model-v1:0`: region and vendor are words and a dot, a version is not (gpt-5.1).
    while let Some(dot) = m.find('.') {
        let (head, rest) = (&m[..dot], &m[dot + 1..]);
        if head.is_empty() || !head.chars().all(|c| c.is_ascii_alphabetic()) || rest.is_empty() {
            break;
        }
        m = rest.to_string();
    }
    if let Some(v) = m.rfind("-v")
        && stamp(&m[v + 2..])
    {
        m.truncate(v);
    }
    // A date: -20251001, or -2024-08-06.
    let parts: Vec<&str> = m.split('-').collect();
    let digits = |s: &str, n: usize| s.len() == n && s.chars().all(|c| c.is_ascii_digit());
    let n = parts.len();
    if n > 1 && digits(parts[n - 1], 8) {
        m = parts[..n - 1].join("-");
    } else if n > 3 && digits(parts[n - 3], 4) && digits(parts[n - 2], 2) && digits(parts[n - 1], 2) {
        m = parts[..n - 3].join("-");
    }
    m + &context
}

/// Bedrock's version stamp after `-v`: `1:0` (not a model's own v4).
fn stamp(s: &str) -> bool {
    let Some((major, minor)) = s.split_once(':') else {
        return false;
    };
    let num = |t: &str| !t.is_empty() && t.chars().all(|c| c.is_ascii_digit());
    num(major) && num(minor)
}

/// Two spellings are one model.
pub fn same_model(a: &str, b: &str) -> bool {
    a == b || model_key(a) == model_key(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_model_is_the_same_however_it_is_spelled() {
        assert_eq!(model_key("anthropic/claude-opus-5-5"), "claude-opus-5-5");
        assert_eq!(
            model_key("us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            "claude-sonnet-4-5"
        );
        assert_eq!(model_key("gpt-5.1"), "gpt-5.1");
        assert_eq!(model_key("gpt-4o-2024-08-06"), "gpt-4o");
        assert_eq!(model_key("Claude-Opus-5-5[1m]"), "claude-opus-5-5[1m]");
        assert_eq!(model_key("gemini-2.5-pro@001"), "gemini-2.5-pro");
        assert!(same_model("openai/gpt-6-astra", "gpt-6-astra"));
        assert!(!same_model("gemini-2.5-flash", "gemini-2.5-flash-lite"));
    }
}
