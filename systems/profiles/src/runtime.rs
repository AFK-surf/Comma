//! How a runtime (Claude Code, Codex) is given a Profile: the runtimes it can run, the environment its processes start
//! with, and the provider Codex is told of (as `-c` overrides, so config.toml stays the person's). `{route}` in a value is
//! a session's routing id, put in where the process starts.
//!
//! Anthropic's and OpenCode Go's keys came before the list of sources and keep what they set: an Anthropic key is only
//! `ANTHROPIC_API_KEY`; OpenCode Go has a provider of its own in Codex (`opencode-go`), and Claude Code's small model on
//! it is `deepseek-flash` unless the Profile names one.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::model::{Credential, Profile};
use crate::sources::{Auth, Endpoints, Source, endpoints, find};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Runtime {
    Claude,
    Codex,
}

pub const OPENCODE_GO: &str = "https://opencode.ai/zen/go";
/// The key the runtimes are given where the Profile has none (a provider that works without): they ask for one.
const NO_KEY: &str = "none";
/// The variable a Codex provider config reads an API provider's key from.
const CODEX_KEY: &str = "EMBER_API_KEY";
/// Codex features the agents have no use for, off for every Profile: apps starts the ChatGPT connectors' MCP server;
/// plugins downloads the plugin marketplace (about 100 MB) into each home's `.tmp` at every start, which a Cloud VM
/// then archives and restores once per session; recommended_plugins lists plugins not installed.
const CODEX_FEATURES_OFF: [(&str, &str); 3] = [
    ("features.apps", "false"),
    ("features.plugins", "false"),
    ("features.recommended_plugins", "false"),
];

/// What a runtime's processes are started with for a Profile.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeConfig {
    pub env: BTreeMap<String, String>,
    /// Codex's `-c key=value` overrides (TOML values), in key order.
    pub codex_overrides: Vec<(String, String)>,
}

/// An API key Profile's source and where it speaks, when its source is known and its address usable.
fn api_source(profile: &Profile) -> Option<(&'static Source, Endpoints)> {
    let source = find(&profile.source)?;
    let at = endpoints(source, profile.endpoint.as_deref(), profile.protocol)?;
    Some((source, at))
}

/// The runtimes a Profile can run: an OpenCode Go key both, an Anthropic key Claude Code, another key what its source
/// speaks (Anthropic's protocol is Claude Code's, Responses Codex's); a sign-in or variables the runtime they are for.
pub fn runtimes(profile: &Profile) -> Vec<Runtime> {
    match profile.credential {
        Credential::ApiKey => match profile.source.as_str() {
            "opencode-go" => vec![Runtime::Claude, Runtime::Codex],
            "anthropic" => vec![Runtime::Claude],
            _ => api_source(profile)
                .map(|(_, at)| {
                    let mut out = vec![];
                    if at.anthropic.is_some() {
                        out.push(Runtime::Claude);
                    }
                    if at.responses.is_some() {
                        out.push(Runtime::Codex);
                    }
                    out
                })
                .unwrap_or_default(),
        },
        _ => profile.runtime.into_iter().collect(),
    }
}

fn opencode_go_env(runtime: Runtime, key: &str, model: Option<&str>) -> BTreeMap<String, String> {
    let pairs: Vec<(&str, String)> = match runtime {
        Runtime::Claude => {
            let small = model.unwrap_or("deepseek-flash").to_string();
            vec![
                ("ANTHROPIC_BASE_URL", OPENCODE_GO.into()),
                ("ANTHROPIC_API_KEY", key.into()),
                ("ANTHROPIC_CUSTOM_HEADERS", "x-opencode-session: {route}".into()),
                // Claude Code's background calls use a small model; point it at one the provider has.
                ("ANTHROPIC_DEFAULT_HAIKU_MODEL", small.clone()),
                ("ANTHROPIC_SMALL_FAST_MODEL", small),
                ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1".into()),
            ]
        }
        // The provider's session key keeps the name of before the rename: its sessions go on under it.
        Runtime::Codex => vec![
            ("OPENCODE_GO_KEY", key.into()),
            ("OPENCODE_SESSION", "ember-{route}".into()),
        ],
    };
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

/// A provider's key for a runtime, from where the provider speaks: Claude Code reads its Anthropic endpoint, Codex its
/// Responses endpoint (the provider's config is in the overrides).
fn api_env(profile: &Profile, runtime: Runtime, key: &str) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    let Some((source, at)) = api_source(profile) else {
        return env;
    };
    let key = if key.is_empty() { NO_KEY } else { key };
    let mut set = |k: &str, v: &str| {
        env.insert(k.to_string(), v.to_string());
    };
    match runtime {
        Runtime::Claude => {
            let Some(base) = at.anthropic else {
                return BTreeMap::new();
            };
            set("ANTHROPIC_BASE_URL", &base);
            match profile.auth.unwrap_or(source.auth) {
                Auth::ApiKey => set("ANTHROPIC_API_KEY", key),
                // The key is a bearer token; a key variable left unset is not asked about.
                Auth::Bearer => {
                    set("ANTHROPIC_AUTH_TOKEN", key);
                    set("ANTHROPIC_API_KEY", "");
                }
                Auth::Both => {
                    set("ANTHROPIC_AUTH_TOKEN", key);
                    set("ANTHROPIC_API_KEY", key);
                }
            }
            if source.session_header {
                set("ANTHROPIC_CUSTOM_HEADERS", "x-opencode-session: {route}");
            }
            // Claude Code's background calls use a small model; where the Profile names one, it is that.
            if let Some(model) = profile.model.as_deref() {
                set("ANTHROPIC_DEFAULT_HAIKU_MODEL", model);
                set("ANTHROPIC_SMALL_FAST_MODEL", model);
            }
            set("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1");
        }
        Runtime::Codex => {
            if at.responses.is_none() {
                return BTreeMap::new();
            }
            set(CODEX_KEY, key);
            if source.session_header {
                set("OPENCODE_SESSION", "ember-{route}");
            }
        }
    }
    env
}

/// Codex's model provider for a Profile, as `-c` overrides (TOML values), in key order.
pub fn codex_overrides(profile: &Profile) -> Vec<(String, String)> {
    let mut out: BTreeMap<String, String> = CODEX_FEATURES_OFF
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    let model = profile.model.as_deref();
    let mut set = |k: &str, v: String| {
        out.insert(k.to_string(), v);
    };
    let quoted = |s: &str| serde_json::to_string(s).expect("a string");
    if profile.credential == Credential::ApiKey && profile.source == "opencode-go" {
        set("model_provider", "\"opencode-go\"".into());
        if let Some(m) = model {
            set("model", quoted(m));
        }
        set("model_providers.opencode-go.name", "\"OpenCode Go\"".into());
        set("model_providers.opencode-go.base_url", format!("\"{OPENCODE_GO}/v1\""));
        set("model_providers.opencode-go.env_key", "\"OPENCODE_GO_KEY\"".into());
        set("model_providers.opencode-go.wire_api", "\"responses\"".into());
        set(
            "model_providers.opencode-go.env_http_headers",
            "{\"x-opencode-session\"=\"OPENCODE_SESSION\"}".into(),
        );
    } else if profile.credential == Credential::ApiKey
        && profile.source != "anthropic"
        && let Some((source, at)) = api_source(profile)
        && let Some(base) = at.responses
    {
        // Codex keeps its own names for the providers it has built in (openai among them): this one is just `api`.
        set("model_provider", "\"api\"".into());
        if let Some(m) = model {
            set("model", quoted(m));
        }
        set("model_providers.api.name", quoted(&source.name));
        set("model_providers.api.base_url", quoted(&base));
        set("model_providers.api.env_key", format!("\"{CODEX_KEY}\""));
        set("model_providers.api.wire_api", "\"responses\"".into());
        if source.session_header {
            set(
                "model_providers.api.env_http_headers",
                "{\"x-opencode-session\"=\"OPENCODE_SESSION\"}".into(),
            );
        }
    }
    out.into_iter().collect()
}

/// The environment and Codex overrides for a Profile's processes of `runtime` (none for a runtime it does not run).
/// `key` is the Profile's key (an API key's), kept apart from the Profile. The Profile's own variables win.
pub fn runtime_config(profile: &Profile, runtime: Runtime, key: &str) -> RuntimeConfig {
    if !runtimes(profile).contains(&runtime) {
        return RuntimeConfig::default();
    }
    let key = key.trim();
    let mut env = match (profile.credential, profile.source.as_str()) {
        (Credential::ApiKey, "opencode-go") => opencode_go_env(runtime, key, profile.model.as_deref()),
        (Credential::ApiKey, "anthropic") => BTreeMap::from([("ANTHROPIC_API_KEY".to_string(), key.to_string())]),
        (Credential::ApiKey, _) => api_env(profile, runtime, key),
        _ => BTreeMap::new(),
    };
    env.extend(profile.env.clone());
    RuntimeConfig {
        env,
        codex_overrides: if runtime == Runtime::Codex {
            codex_overrides(profile)
        } else {
            Vec::new()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key_profile(source: &str, endpoint: Option<&str>) -> Profile {
        serde_json::from_value(
            serde_json::json!({"id": "p", "source": source, "credential": "api_key", "endpoint": endpoint}),
        )
        .unwrap()
    }

    #[test]
    fn a_key_runs_what_its_source_speaks() {
        assert_eq!(runtimes(&key_profile("openrouter", None)), [Runtime::Claude]);
        assert_eq!(runtimes(&key_profile("openai", None)), [Runtime::Codex]);
        assert_eq!(
            runtimes(&key_profile("opencode-go", None)),
            [Runtime::Claude, Runtime::Codex]
        );
        assert_eq!(runtimes(&key_profile("groq", None)), []);
        assert_eq!(
            runtimes(&key_profile("custom", Some("http://h/v1"))),
            [Runtime::Claude, Runtime::Codex]
        );
    }

    #[test]
    fn claude_code_is_given_the_key_as_its_source_takes_it() {
        let mut p = key_profile("openrouter", None);
        p.model = Some("deepseek/deepseek-v4".into());
        let env = runtime_config(&p, Runtime::Claude, "sk").env;
        assert_eq!(env["ANTHROPIC_BASE_URL"], "https://openrouter.ai/api");
        assert_eq!(
            (env["ANTHROPIC_AUTH_TOKEN"].as_str(), env["ANTHROPIC_API_KEY"].as_str()),
            ("sk", "")
        );
        assert_eq!(env["ANTHROPIC_SMALL_FAST_MODEL"], "deepseek/deepseek-v4");
        assert_eq!(
            runtime_config(&key_profile("anthropic", None), Runtime::Claude, "sk").env,
            BTreeMap::from([("ANTHROPIC_API_KEY".into(), "sk".into())])
        );
        let go = runtime_config(&key_profile("opencode-go", None), Runtime::Claude, "k").env;
        assert_eq!(
            (
                go["ANTHROPIC_SMALL_FAST_MODEL"].as_str(),
                go["ANTHROPIC_CUSTOM_HEADERS"].as_str()
            ),
            ("deepseek-flash", "x-opencode-session: {route}")
        );
        let custom = runtime_config(&key_profile("custom", Some("http://h/v1")), Runtime::Claude, "").env;
        assert_eq!(
            (
                custom["ANTHROPIC_AUTH_TOKEN"].as_str(),
                custom["ANTHROPIC_BASE_URL"].as_str()
            ),
            ("none", "http://h")
        );
    }

    #[test]
    fn codex_is_told_of_the_provider_and_the_profiles_variables_win() {
        let mut p = key_profile("openai", None);
        p.model = Some("gpt-5.5".into());
        p.env.insert("EMBER_API_KEY".into(), "mine".into());
        let config = runtime_config(&p, Runtime::Codex, "sk");
        assert_eq!(config.env["EMBER_API_KEY"], "mine");
        let overrides: BTreeMap<_, _> = config.codex_overrides.into_iter().collect();
        assert_eq!(overrides["model_provider"], "\"api\"");
        assert_eq!(
            overrides["model_providers.api.base_url"],
            "\"https://api.openai.com/v1\""
        );
        assert_eq!(overrides["model"], "\"gpt-5.5\"");
        assert_eq!(overrides["features.apps"], "false");
        assert_eq!(overrides["features.plugins"], "false");
        let go: BTreeMap<_, _> = codex_overrides(&key_profile("opencode-go", None)).into_iter().collect();
        assert_eq!(
            go["model_providers.opencode-go.base_url"],
            "\"https://opencode.ai/zen/go/v1\""
        );
        let sub: Profile = serde_json::from_value(
            serde_json::json!({"id": "s", "source": "codex", "credential": "subscription", "runtime": "codex"}),
        )
        .unwrap();
        assert_eq!(codex_overrides(&sub).len(), 3);
        assert_eq!(runtime_config(&sub, Runtime::Claude, ""), RuntimeConfig::default());
    }
}
