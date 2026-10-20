//! Process configuration, read once from the environment at startup.

use std::{net::SocketAddr, time::Duration};

use anyhow::{Context, Result, bail};
use iroh::{RelayUrl, SecretKey};

/// Everything the gateway reads from its environment.
#[derive(Debug, Clone)]
pub struct Config {
    /// The persistent iroh identity. Its public key is the node id that Comma
    /// publishes to stations as a `gateway_keys` entry.
    pub secret_key: SecretKey,
    /// Bearer token Salix presents on `POST /v1/stations/:id/tools`.
    pub token: String,
    /// Comma's iroh relays. Empty disables relays (direct addresses only).
    pub relay_urls: Vec<RelayUrl>,
    /// Look up a station's relay and addresses on the Mainline DHT, where
    /// stations publish them.
    pub dht_lookup: bool,
    /// Tools API listener (Salix traffic).
    pub api_listen: SocketAddr,
    /// Health and metrics listener.
    pub admin_listen: SocketAddr,
    pub timeouts: Timeouts,
    pub limits: Limits,
}

#[derive(Debug, Clone, Copy)]
pub struct Timeouts {
    /// Upper bound for dialing a station that has no live connection.
    pub connect: Duration,
    /// Default bound for one tool request, from receipt to the response line.
    pub request: Duration,
    /// Ceiling for a request whose `args.timeout_ms` asks for longer.
    pub max_request: Duration,
    /// A cached station connection unused for this long is closed.
    pub idle: Duration,
}

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Cached station connections; the least recently used idle one is closed
    /// when a new station needs a slot.
    pub max_connections: usize,
    /// Tool requests in flight at once; more are refused with 503.
    pub max_in_flight: usize,
}

impl Default for Timeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(10),
            request: Duration::from_secs(60),
            max_request: Duration::from_secs(15 * 60),
            idle: Duration::from_secs(5 * 60),
        }
    }
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_connections: 1024,
            max_in_flight: 256,
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self> {
        let value = |name: &str| {
            get(name)
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        };
        let secret_key = secret_key(&value)?;
        let token = value("COMMA_STATION_GATEWAY_TOKEN")
            .context("COMMA_STATION_GATEWAY_TOKEN is required")?;
        if token.len() < 32 {
            bail!("COMMA_STATION_GATEWAY_TOKEN must be at least 32 characters");
        }
        let relay_urls = value("COMMA_STATION_RELAY_URLS")
            .map(|list| parse_relay_urls(&list))
            .transpose()?
            .unwrap_or_default();
        let defaults = Timeouts::default();
        let limits = Limits::default();
        let millis = |name: &str, default: Duration| -> Result<Duration> {
            match value(name) {
                None => Ok(default),
                Some(v) => {
                    let ms: u64 = v
                        .parse()
                        .with_context(|| format!("{name} must be milliseconds"))?;
                    if ms == 0 {
                        bail!("{name} must be positive");
                    }
                    Ok(Duration::from_millis(ms))
                }
            }
        };
        let count = |name: &str, default: usize| -> Result<usize> {
            match value(name) {
                None => Ok(default),
                Some(v) => match v.parse::<usize>() {
                    Ok(n) if n > 0 => Ok(n),
                    _ => bail!("{name} must be a positive integer"),
                },
            }
        };
        let timeouts = Timeouts {
            connect: millis("COMMA_STATION_CONNECT_TIMEOUT_MS", defaults.connect)?,
            request: millis("COMMA_STATION_REQUEST_TIMEOUT_MS", defaults.request)?,
            max_request: millis("COMMA_STATION_MAX_REQUEST_TIMEOUT_MS", defaults.max_request)?,
            idle: millis("COMMA_STATION_IDLE_TIMEOUT_MS", defaults.idle)?,
        };
        if timeouts.max_request < timeouts.request {
            bail!(
                "COMMA_STATION_MAX_REQUEST_TIMEOUT_MS must not be below COMMA_STATION_REQUEST_TIMEOUT_MS"
            );
        }
        Ok(Self {
            secret_key,
            token,
            relay_urls,
            dht_lookup: !matches!(
                value("COMMA_STATION_DHT_LOOKUP").as_deref(),
                Some("0" | "false")
            ),
            api_listen: listen(&value, "COMMA_STATION_GATEWAY_LISTEN", "0.0.0.0:8080")?,
            admin_listen: listen(&value, "COMMA_STATION_GATEWAY_ADMIN_LISTEN", "0.0.0.0:9090")?,
            timeouts,
            limits: Limits {
                max_connections: count("COMMA_STATION_MAX_CONNECTIONS", limits.max_connections)?,
                max_in_flight: count("COMMA_STATION_GATEWAY_MAX_IN_FLIGHT", limits.max_in_flight)?,
            },
        })
    }
}

/// The identity from `COMMA_STATION_GATEWAY_SECRET_KEY` (64 hex characters) or
/// the file named by `COMMA_STATION_GATEWAY_SECRET_KEY_FILE`.
pub fn secret_key(value: &impl Fn(&str) -> Option<String>) -> Result<SecretKey> {
    let encoded = match (
        value("COMMA_STATION_GATEWAY_SECRET_KEY"),
        value("COMMA_STATION_GATEWAY_SECRET_KEY_FILE"),
    ) {
        (Some(key), None) => key,
        (None, Some(path)) => std::fs::read_to_string(&path)
            .with_context(|| format!("read COMMA_STATION_GATEWAY_SECRET_KEY_FILE {path}"))?
            .trim()
            .to_string(),
        (Some(_), Some(_)) => bail!(
            "set only one of COMMA_STATION_GATEWAY_SECRET_KEY and COMMA_STATION_GATEWAY_SECRET_KEY_FILE"
        ),
        (None, None) => bail!(
            "COMMA_STATION_GATEWAY_SECRET_KEY or COMMA_STATION_GATEWAY_SECRET_KEY_FILE is required"
        ),
    };
    let bytes: [u8; 32] = hex::decode(&encoded)
        .ok()
        .and_then(|b| b.try_into().ok())
        .context("the gateway secret key must be 64 hex characters")?;
    Ok(SecretKey::from_bytes(&bytes))
}

pub fn parse_relay_urls(list: &str) -> Result<Vec<RelayUrl>> {
    list.split([',', ' ', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            s.parse::<RelayUrl>()
                .with_context(|| format!("invalid relay URL {s}"))
        })
        .collect()
}

fn listen(
    value: &impl Fn(&str) -> Option<String>,
    name: &str,
    default: &str,
) -> Result<SocketAddr> {
    let raw = value(name).unwrap_or_else(|| default.to_string());
    raw.parse()
        .with_context(|| format!("{name} must be host:port"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn config(vars: &[(&str, &str)]) -> Result<Config> {
        let vars: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        Config::from_lookup(|name| vars.get(name).cloned())
    }

    const KEY: &str = "0101010101010101010101010101010101010101010101010101010101010101";
    const TOKEN: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn reads_identity_relays_and_defaults() {
        let config = config(&[
            ("COMMA_STATION_GATEWAY_SECRET_KEY", KEY),
            ("COMMA_STATION_GATEWAY_TOKEN", TOKEN),
            (
                "COMMA_STATION_RELAY_URLS",
                "https://relay-a.example.com, https://relay-b.example.com",
            ),
        ])
        .unwrap();
        assert_eq!(config.secret_key.to_bytes(), [1u8; 32]);
        assert_eq!(config.relay_urls.len(), 2);
        assert!(config.dht_lookup);
        assert_eq!(config.timeouts.request, Duration::from_secs(60));
        assert_eq!(config.api_listen.port(), 8080);
    }

    #[test]
    fn rejects_missing_or_weak_credentials() {
        assert!(config(&[("COMMA_STATION_GATEWAY_TOKEN", TOKEN)]).is_err());
        assert!(
            config(&[
                ("COMMA_STATION_GATEWAY_SECRET_KEY", KEY),
                ("COMMA_STATION_GATEWAY_TOKEN", "short")
            ])
            .is_err()
        );
        assert!(
            config(&[
                ("COMMA_STATION_GATEWAY_SECRET_KEY", "abcd"),
                ("COMMA_STATION_GATEWAY_TOKEN", TOKEN)
            ])
            .is_err()
        );
    }
}
