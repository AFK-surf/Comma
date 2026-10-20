//! What a Profile connects to: a lab's or a gateway's API with a key, or a subscription. `sources.json` is generated with
//! the model catalog (scripts/generate-model-catalog.mjs): Comma's catalog lists the same sources, less the
//! station-only ones.

use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    ChatCompletions,
    Responses,
    Anthropic,
}

impl Protocol {
    pub const ALL: [Protocol; 3] = [Protocol::ChatCompletions, Protocol::Responses, Protocol::Anthropic];

    pub fn parse(text: &str) -> Option<Protocol> {
        Protocol::ALL.into_iter().find(|p| p.name() == text)
    }

    pub fn name(self) -> &'static str {
        match self {
            Protocol::ChatCompletions => "chat_completions",
            Protocol::Responses => "responses",
            Protocol::Anthropic => "anthropic",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    ApiKey,
    Subscription,
}

/// How Claude Code is given the key: some endpoints read `x-api-key`, others a bearer token, a few either.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Auth {
    ApiKey,
    Bearer,
    Both,
}

/// Where a source answers each protocol.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Endpoints {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat_completions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub responses: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anthropic: Option<String>,
    /// A native decision endpoint (Jev's), for a station's automatic decisions only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub kind: SourceKind,
    pub endpoints: Endpoints,
    /// For one at the person's own address: the protocols it can speak there.
    pub protocols: Vec<Protocol>,
    /// The address is the person's (Azure, Cloudflare, Ollama, Custom), not the provider's.
    pub endpoint_required: bool,
    /// Works without a key (a server of one's own).
    pub key_optional: bool,
    pub auth: Auth,
    /// OpenCode's gateways refuse a request without `x-opencode-session`.
    pub session_header: bool,
    /// Only a station reaches it (an address on its own network, its decisions' endpoint).
    pub station_only: bool,
    /// How the pickers group it: labs, gateways, hosted, local.
    pub group: String,
}

/// Every source, in the order they are offered.
pub fn sources() -> &'static [Source] {
    static SOURCES: OnceLock<Vec<Source>> = OnceLock::new();
    SOURCES.get_or_init(|| serde_json::from_str(include_str!("../sources.json")).expect("sources.json"))
}

pub fn find(id: &str) -> Option<&'static Source> {
    sources().iter().find(|s| s.id == id)
}

/// An address as it is kept: trimmed, without a trailing slash; none unless it is an http(s) address.
pub fn clean_endpoint(text: &str) -> Option<String> {
    let trimmed = text.trim().trim_end_matches('/');
    let rest = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))?;
    (!rest.is_empty() && !rest.chars().any(char::is_whitespace)).then(|| trimmed.to_string())
}

/// The endpoints of a source; for one at the person's own address, derived from it and the protocol chosen for it (none
/// chosen: all it can speak). None when the address is needed and is not a usable one, or the protocol is one the source
/// does not speak.
pub fn endpoints(source: &Source, endpoint: Option<&str>, protocol: Option<Protocol>) -> Option<Endpoints> {
    if !source.endpoint_required {
        return Some(source.endpoints.clone());
    }
    let base = clean_endpoint(endpoint?)?;
    if let Some(chosen) = protocol
        && !source.protocols.contains(&chosen)
    {
        return None;
    }
    let only = |p: Protocol, url: String| Endpoints {
        chat_completions: (p == Protocol::ChatCompletions).then(|| url.clone()),
        responses: (p == Protocol::Responses).then(|| url.clone()),
        anthropic: (p == Protocol::Anthropic).then(|| url.clone()),
        decision: None,
    };
    Some(match source.id.as_str() {
        "cloudflare-ai-gateway" => {
            // The gateway's address (…/v1/<account>/<gateway>): each protocol under its own path.
            let root = ["/compat", "/openai", "/anthropic"]
                .iter()
                .find_map(|s| base.strip_suffix(s))
                .unwrap_or(&base);
            let all = Endpoints {
                chat_completions: Some(format!("{root}/compat")),
                responses: Some(format!("{root}/openai")),
                anthropic: Some(format!("{root}/anthropic")),
                decision: None,
            };
            match protocol {
                None => all,
                Some(Protocol::ChatCompletions) => Endpoints {
                    responses: None,
                    anthropic: None,
                    ..all
                },
                Some(Protocol::Responses) => Endpoints {
                    chat_completions: None,
                    anthropic: None,
                    ..all
                },
                Some(Protocol::Anthropic) => Endpoints {
                    chat_completions: None,
                    responses: None,
                    ..all
                },
            }
        }
        "azure-openai" => only(Protocol::Responses, base),
        "cloudflare-workers-ai" | "ollama" => only(Protocol::ChatCompletions, base),
        _ => match protocol {
            Some(p) => only(p, base),
            // Before the choice existed an address was taken for every protocol (Anthropic's at the root above a /v1).
            None => Endpoints {
                anthropic: base.strip_suffix("/v1").map(str::to_string),
                chat_completions: Some(base.clone()),
                responses: Some(base),
                decision: None,
            },
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sources_are_those_of_the_catalog_and_the_stations() {
        let ids: Vec<&str> = sources().iter().map(|s| s.id.as_str()).collect();
        for id in [
            "openai",
            "anthropic",
            "opencode-go",
            "custom",
            "codex",
            "claude",
            "gemini",
            "ollama",
            "jev",
        ] {
            assert!(ids.contains(&id), "{id}");
        }
        assert_eq!(find("anthropic").unwrap().auth, Auth::ApiKey);
        assert!(find("ollama").unwrap().station_only);
        assert_eq!(find("codex").unwrap().kind, SourceKind::Subscription);
    }

    #[test]
    fn a_persons_address_makes_the_endpoints() {
        let gateway = find("cloudflare-ai-gateway").unwrap();
        let at = endpoints(gateway, Some("https://gateway.ai.cloudflare.com/v1/a/g/openai/"), None).unwrap();
        assert_eq!(
            at.chat_completions.as_deref(),
            Some("https://gateway.ai.cloudflare.com/v1/a/g/compat")
        );
        assert_eq!(
            at.anthropic.as_deref(),
            Some("https://gateway.ai.cloudflare.com/v1/a/g/anthropic")
        );
        let custom = find("custom").unwrap();
        let legacy = endpoints(custom, Some("http://host:8000/v1"), None).unwrap();
        assert_eq!(legacy.anthropic.as_deref(), Some("http://host:8000"));
        assert_eq!(
            endpoints(custom, Some("http://host/v1"), Some(Protocol::Responses))
                .unwrap()
                .responses
                .as_deref(),
            Some("http://host/v1")
        );
        assert_eq!(endpoints(custom, Some("not an address"), None), None);
        assert_eq!(
            endpoints(
                find("azure-openai").unwrap(),
                Some("https://x"),
                Some(Protocol::Anthropic)
            ),
            None
        );
        assert_eq!(
            endpoints(find("openai").unwrap(), None, None)
                .unwrap()
                .responses
                .as_deref(),
            Some("https://api.openai.com/v1")
        );
    }
}
