//! For testing a station on one machine (station/test): a test workspace for it, and a client to try it with.
//!
//! `station-load setup <data>`: a test workspace for a station's data directory: its key (mesh/secret.key), and
//! mesh/cloud.json with a grant key of our own (its private half in <data>/grant.key), so that credentials this tool
//! signs are a member's. The rest of cloud.json (relays, origin) is the caller's to fill in.
//! `station-load ask <data> <station id> <ip:port,…> <path>`: one request, its answer's head on stderr, its body on stdout.
//! With CREDENTIAL_URL (a dev cloud's `/__dev/credential`), the credential is the cloud's for this device instead of
//! one signed with <data>/grant.key; a station id with no addresses (`-`) is reached through relays and discovery.
//! `station-load load <data> <station id> <ip:port,…> <seconds> <concurrency> <path>…`: requests on one connection,
//! `concurrency` at a time, round-robin over the paths, for `seconds`; how they went.

use std::net::SocketAddr;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use ed25519_dalek::{Signer, SigningKey};
use iroh::endpoint::{Connection, presets::Minimal};
use iroh::{Endpoint, EndpointAddr, PublicKey, RelayMode};
use serde_json::{Value, json};

const ALPN: &[u8] = b"stillfail/admin/1";
const WORKSPACE: &str = "test-workspace";

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["setup", data] => setup(Path::new(data)),
        ["ask", data, id, addrs, path] => {
            let conn = connect(Path::new(data), id, addrs).await?;
            let (head, body) = request(&conn, path).await?;
            eprintln!("{head}");
            println!("{}", String::from_utf8_lossy(&body));
            Ok(())
        }
        // One write: its head line on stderr, its body on stdout.
        ["send", data, id, addrs, method, path, body] => {
            let conn = connect(Path::new(data), id, addrs).await?;
            let (mut send, mut recv) = conn.open_bi().await?;
            send.write_all(format!("{}\n{body}", json!({ "method": method, "path": path, "headers": {} })).as_bytes()).await?;
            send.finish()?;
            let all = recv.read_to_end(256 << 20).await?;
            let at = all.iter().position(|b| *b == b'\n').context("no head")?;
            eprintln!("{}", String::from_utf8_lossy(&all[..at]));
            println!("{}", String::from_utf8_lossy(&all[at + 1..]));
            Ok(())
        }
        // An event stream followed for `seconds`, printed as it comes; meanwhile each `METHOD path body` write asked
        // on the same connection, a second apart.
        ["follow", data, id, addrs, seconds, path, writes @ ..] => {
            let conn = connect(Path::new(data), id, addrs).await?;
            let (mut send, mut recv) = conn.open_bi().await?;
            send.write_all(format!("{}\n", json!({ "method": "GET", "path": path, "headers": {} })).as_bytes()).await?;
            send.finish()?;
            let writer = {
                let conn = conn.clone();
                let writes: Vec<String> = writes.iter().map(|w| w.to_string()).collect();
                tokio::spawn(async move {
                    for w in writes {
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        let mut parts = w.splitn(3, ' ');
                        let (method, path, body) = (parts.next().unwrap_or("GET"), parts.next().unwrap_or("/"), parts.next().unwrap_or(""));
                        let Ok((mut s, mut r)) = conn.open_bi().await else { return };
                        let _ = s.write_all(format!("{}\n{body}", json!({ "method": method, "path": path, "headers": {} })).as_bytes()).await;
                        let _ = s.finish();
                        let all = r.read_to_end(1 << 20).await.unwrap_or_default();
                        eprintln!("-> {method} {path}: {}", String::from_utf8_lossy(&all).replace('\n', " "));
                    }
                })
            };
            let until = Instant::now() + Duration::from_secs(seconds.parse()?);
            let mut buf = vec![0u8; 64 * 1024];
            while let Ok(read) = tokio::time::timeout_at(until.into(), recv.read(&mut buf)).await {
                match read? {
                    Some(n) => print!("{}", String::from_utf8_lossy(&buf[..n])),
                    None => break,
                }
            }
            writer.abort();
            Ok(())
        }
        ["load", data, id, addrs, seconds, concurrency, paths @ ..] if !paths.is_empty() => {
            let conn = connect(Path::new(data), id, addrs).await?;
            load(conn, Duration::from_secs(seconds.parse()?), concurrency.parse()?, paths.iter().map(|p| p.to_string()).collect()).await
        }
        _ => bail!("usage: station-load setup <data> | ask <data> <id> <addrs> <path> | load <data> <id> <addrs> <seconds> <concurrency> <path>…"),
    }
}

fn setup(data: &Path) -> Result<()> {
    std::fs::create_dir_all(data.join("mesh"))?;
    let station = iroh::SecretKey::generate();
    std::fs::write(data.join("mesh").join("secret.key"), station.to_bytes())?;
    let grant = SigningKey::generate(&mut rand::rngs::OsRng);
    std::fs::write(data.join("grant.key"), grant.to_bytes())?;
    let cloud = json!({
        "origin": "http://127.0.0.1:9", "station": hex::encode(station.public().as_bytes()), "workspace": WORKSPACE,
        "workspace_name": "测试", "name": "测试 station", "relay_url": "", "relay_urls": [],
        "grant_keys": { "keys": [{ "kty": "OKP", "crv": "Ed25519", "kid": "test", "x": B64.encode(grant.verifying_key().as_bytes()) }] },
        "peers": [], "revocations": [],
    });
    std::fs::write(data.join("mesh").join("cloud.json"), serde_json::to_string_pretty(&cloud)?)?;
    println!("{}", hex::encode(station.public().as_bytes()));
    Ok(())
}

/// A member's credential for this device: the dev cloud's (CREDENTIAL_URL), else one signed as still.fail cloud signs.
fn credential(data: &Path, device: &str) -> Result<String> {
    if let Ok(url) = std::env::var("CREDENTIAL_URL") {
        return dev_credential(&url, device);
    }
    let bytes: [u8; 32] = std::fs::read(data.join("grant.key"))?.try_into().map_err(|_| anyhow::anyhow!("grant.key"))?;
    let grant = SigningKey::from_bytes(&bytes);
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let email = std::env::var("VIEWER").unwrap_or_else(|_| "zuozijian1994@gmail.com".into());
    let head = B64.encode(json!({ "alg": "EdDSA", "typ": "stillfail-member+jwt", "kid": "test" }).to_string());
    let body = B64.encode(json!({
        "iss": "stillfail-cloud", "ws": WORKSPACE, "device": device, "sub": "test-account", "email": email, "name": "测试",
        "role": "owner", "sid": "test-session", "iat": now, "exp": now + 3600,
    }).to_string());
    let sig = B64.encode(grant.sign(format!("{head}.{body}").as_bytes()).to_bytes());
    Ok(format!("{head}.{body}.{sig}"))
}

/// GET <url>?device=<hex> over plain HTTP (a dev cloud on this machine): `{credential}`.
fn dev_credential(url: &str, device: &str) -> Result<String> {
    use std::io::{Read, Write};
    let rest = url.strip_prefix("http://").context("CREDENTIAL_URL: http only")?;
    let (host, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let mut tcp = std::net::TcpStream::connect(host)?;
    write!(tcp, "GET {path}?device={device} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")?;
    let mut answer = String::new();
    tcp.read_to_string(&mut answer)?;
    // The JSON whole, whatever framing it came in (chunked or not).
    let body = answer.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");
    let json = body.find('{').zip(body.rfind('}')).map(|(a, b)| &body[a..=b]).unwrap_or(body);
    let value: Value = serde_json::from_str(json).with_context(|| format!("credential answer: {body}"))?;
    value["credential"].as_str().map(str::to_string).with_context(|| format!("no credential in {value}"))
}

async fn connect(data: &Path, id: &str, addrs: &str) -> Result<Connection> {
    let bytes: [u8; 32] = hex::decode(id)?.try_into().map_err(|_| anyhow::anyhow!("station id"))?;
    let mut addr = EndpointAddr::new(PublicKey::from_bytes(&bytes)?);
    for a in addrs.split(',').filter(|a| !a.is_empty() && *a != "-") {
        addr = addr.with_ip_addr(a.parse::<SocketAddr>()?);
    }
    // Relays (RELAYS, comma-separated) when given: reached as a device far away would.
    let relays: Vec<iroh::RelayUrl> = std::env::var("RELAYS").ok().into_iter().flat_map(|r| r.split(',').filter(|u| !u.is_empty()).map(|u| u.parse()).collect::<Vec<_>>()).collect::<Result<_, _>>()?;
    for relay in &relays {
        addr = addr.with_relay_url(relay.clone());
    }
    let mode = if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(iroh::RelayMap::from_iter(relays)) };
    let endpoint = Endpoint::builder(Minimal).relay_mode(mode).bind().await?;
    let conn = endpoint.connect(addr, ALPN).await?;
    let (mut send, mut recv) = conn.open_bi().await?;
    let device = hex::encode(endpoint.id().as_bytes());
    send.write_all(format!("{}\n", json!({ "credential": credential(data, &device)?, "protocol": 1 })).as_bytes()).await?;
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while recv.read(&mut byte).await?.is_some() && byte[0] != b'\n' {
        line.push(byte[0]);
    }
    let answer: Value = serde_json::from_slice(&line)?;
    if std::env::var("DEBUG").is_ok() {
        eprintln!("load: {answer}");
    }
    if answer["ok"] != true {
        bail!("refused: {answer}");
    }
    // The credential stream stays open for the connection's life, and the endpoint (dropped, it closes) for the program's.
    std::mem::forget((send, recv, endpoint));
    Ok(conn)
}

async fn request(conn: &Connection, path: &str) -> Result<(Value, Vec<u8>)> {
    let debug = std::env::var("DEBUG").is_ok();
    let (mut send, mut recv) = conn.open_bi().await?;
    send.write_all(format!("{}\n", json!({ "method": "GET", "path": path, "headers": {} })).as_bytes()).await?;
    send.finish()?;
    if debug {
        eprintln!("load: asked {path}");
    }
    let all = recv.read_to_end(256 << 20).await?;
    if debug {
        eprintln!("load: {} bytes back", all.len());
    }
    let at = all.iter().position(|b| *b == b'\n').context("no head")?;
    Ok((serde_json::from_slice(&all[..at])?, all[at + 1..].to_vec()))
}

async fn load(conn: Connection, seconds: Duration, concurrency: usize, paths: Vec<String>) -> Result<()> {
    let until = Instant::now() + seconds;
    let mut workers = Vec::new();
    for w in 0..concurrency {
        let (conn, paths) = (conn.clone(), paths.clone());
        workers.push(tokio::spawn(async move {
            let mut took = Vec::new();
            let mut failed = 0usize;
            let mut why: Option<String> = None;
            let mut i = w;
            while Instant::now() < until {
                let started = Instant::now();
                let path = &paths[i % paths.len()];
                match request(&conn, path).await {
                    Ok((head, _)) if head["status"] == 200 => took.push(started.elapsed().as_secs_f64() * 1000.0),
                    Ok((head, body)) => {
                        failed += 1;
                        why.get_or_insert_with(|| format!("{path}: {head} {}", String::from_utf8_lossy(&body)));
                    }
                    Err(error) => {
                        failed += 1;
                        why.get_or_insert_with(|| format!("{path}: {error:#}"));
                    }
                }
                i += concurrency;
            }
            (took, failed, why)
        }));
    }
    let mut took = Vec::new();
    let mut failed = 0;
    let mut why = None;
    for w in workers {
        let (t, f, y) = w.await?;
        took.extend(t);
        failed += f;
        why = why.or(y);
    }
    took.sort_by(f64::total_cmp);
    let at = |q: f64| took.get(((took.len() as f64 - 1.0) * q).round() as usize).copied().unwrap_or(0.0);
    println!("{}", json!({
        "requests": took.len(), "failed": failed, "perSecond": took.len() as f64 / seconds.as_secs_f64(),
        "p50": at(0.5), "p95": at(0.95), "max": at(1.0), "firstFailure": why,
    }));
    Ok(())
}
