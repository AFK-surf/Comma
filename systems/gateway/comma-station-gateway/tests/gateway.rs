//! End-to-end: HTTP request → gateway → iroh `comma/tools/1` → an in-process
//! fake station, over loopback with relays disabled.

use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

use comma_station_gateway::{api, config::Config, state, station::ALPN};
use iroh::{
    Endpoint, EndpointId, RelayMode, SecretKey,
    address_lookup::MemoryLookup,
    endpoint::{Connection, StoppedError, VarInt, presets::Minimal},
};
use serde_json::{Value, json};
use tokio::sync::{Mutex, mpsc};

const TOKEN: &str = "test-token-0123456789abcdef0123456789";

/// How the gateway ended a `hang` stream: the code it stopped it with, or
/// the connection's loss.
type Hung = Result<Option<VarInt>, StoppedError>;

struct FakeStation {
    endpoint: Endpoint,
    connections: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<Value>>>,
    hung: mpsc::UnboundedReceiver<Hung>,
}

impl FakeStation {
    fn id(&self) -> String {
        hex::encode(self.endpoint.id().as_bytes())
    }
}

/// A station that admits only `admitted` and answers by op: `echo` returns
/// the request it saw, `deny` a tool error, `hang` never answers (it says on
/// `hung` how the gateway ended the stream), `garbage` a line that is not
/// JSON.
async fn fake_station(admitted: EndpointId) -> FakeStation {
    let endpoint =
        loopback_endpoint(SecretKey::from_bytes(&rand::random()), vec![ALPN.to_vec()]).await;
    let connections = Arc::new(AtomicUsize::new(0));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let (hung_tx, hung) = mpsc::unbounded_channel();
    let (ep, conns, reqs) = (endpoint.clone(), connections.clone(), requests.clone());
    tokio::spawn(async move {
        while let Some(incoming) = ep.accept().await {
            let Ok(connection) = incoming.await else {
                continue;
            };
            if connection.remote_id() != admitted {
                connection.close(1u32.into(), b"not a gateway key");
                continue;
            }
            conns.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(serve_connection(connection, reqs.clone(), hung_tx.clone()));
        }
    });
    FakeStation {
        endpoint,
        connections,
        requests,
        hung,
    }
}

async fn serve_connection(
    connection: Connection,
    requests: Arc<Mutex<Vec<Value>>>,
    hung: mpsc::UnboundedSender<Hung>,
) {
    while let Ok((mut send, mut recv)) = connection.accept_bi().await {
        let (requests, hung) = (requests.clone(), hung.clone());
        tokio::spawn(async move {
            let raw = recv.read_to_end(1 << 20).await.unwrap();
            let end = raw.iter().position(|b| *b == b'\n').expect("header line");
            let header: Value = serde_json::from_slice(&raw[..end]).unwrap();
            requests.lock().await.push(header.clone());
            let line = match header["op"].as_str().unwrap() {
                "deny" => json!({"ok": false, "error": {"code": "access_denied", "message": "tools.access is read"}}).to_string(),
                "hang" => {
                    // Open and unanswered until the gateway gives up on it.
                    let _ = hung.send(send.stopped().await);
                    return;
                }
                "garbage" => "not json".to_string(),
                _ => json!({"ok": true, "result": {"seen": header}}).to_string(),
            };
            send.write_all(line.as_bytes()).await.unwrap();
            send.write_all(b"\n").await.unwrap();
            send.finish().unwrap();
            let _ = send.stopped().await;
        });
    }
}

async fn loopback_endpoint(secret: SecretKey, alpns: Vec<Vec<u8>>) -> Endpoint {
    Endpoint::builder(Minimal)
        .secret_key(secret)
        .relay_mode(RelayMode::Disabled)
        .alpns(alpns)
        .bind_addr("127.0.0.1:0")
        .unwrap()
        .bind()
        .await
        .unwrap()
}

struct Gateway {
    url: String,
    admin_url: String,
    endpoint: Endpoint,
}

/// A gateway that learns `known` stations' loopback addresses from memory,
/// the way production learns them from the DHT.
async fn gateway(secret: SecretKey, known: &[&Endpoint], env: &[(&str, &str)]) -> Gateway {
    let mut vars: HashMap<String, String> = HashMap::from([
        (
            "COMMA_STATION_GATEWAY_SECRET_KEY".into(),
            hex::encode(secret.to_bytes()),
        ),
        ("COMMA_STATION_GATEWAY_TOKEN".into(), TOKEN.into()),
    ]);
    vars.extend(env.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    let config = Config::from_lookup(|name| vars.get(name).cloned()).unwrap();
    let endpoint = loopback_endpoint(secret, vec![]).await;
    endpoint
        .address_lookup()
        .unwrap()
        .add(MemoryLookup::from_endpoint_info(
            known.iter().map(|station| station.addr()),
        ));
    let state = state(endpoint.clone(), &config);
    let api_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let admin_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", api_listener.local_addr().unwrap());
    let admin_url = format!("http://{}", admin_listener.local_addr().unwrap());
    tokio::spawn(axum::serve(api_listener, api::api_router(state.clone())).into_future());
    tokio::spawn(axum::serve(admin_listener, api::admin_router(state)).into_future());
    Gateway {
        url,
        admin_url,
        endpoint,
    }
}

fn context() -> Value {
    json!({"workspace": "ws_1", "user_id": "usr_1", "user_email": "a@example.com", "agent": "agt_1", "conversation": "conv_1"})
}

async fn post(gateway: &Gateway, station: &str, token: Option<&str>, body: Value) -> (u16, Value) {
    let mut request = reqwest::Client::new()
        .post(format!("{}/v1/stations/{station}/tools", gateway.url))
        .json(&body);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request.send().await.unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap())
}

#[tokio::test]
async fn forwards_the_request_and_reuses_one_connection() {
    let secret = SecretKey::from_bytes(&rand::random());
    let station = fake_station(secret.public()).await;
    let gateway = gateway(secret, &[&station.endpoint], &[]).await;

    let body = json!({"op": "exec", "id": "req-1", "args": {"command": "uname -a", "timeout_ms": 5000}, "context": context()});
    let (status, response) = post(&gateway, &station.id(), Some(TOKEN), body).await;
    assert_eq!(status, 200, "{response}");
    assert_eq!(response["ok"], true);
    let seen = &response["result"]["seen"];
    assert_eq!(seen["op"], "exec");
    assert_eq!(seen["id"], "req-1");
    assert_eq!(seen["args"]["command"], "uname -a");
    assert_eq!(seen["context"], context());

    let (status, response) = post(
        &gateway,
        &station.id(),
        Some(TOKEN),
        json!({"op": "fs.list", "args": {"path": "/"}, "context": context()}),
    )
    .await;
    assert_eq!(status, 200);
    let generated = response["result"]["seen"]["id"].as_str().unwrap();
    assert!(!generated.is_empty(), "a request without id gets one");
    assert_eq!(
        station.connections.load(Ordering::SeqCst),
        1,
        "both requests share one connection"
    );

    let scrape = reqwest::get(format!("{}/metrics", gateway.admin_url))
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(
        scrape.contains(r#"comma_station_gateway_requests_total{op="exec",outcome="ok"} 1"#),
        "{scrape}"
    );
}

#[tokio::test]
async fn returns_tool_errors_as_200() {
    let secret = SecretKey::from_bytes(&rand::random());
    let station = fake_station(secret.public()).await;
    let gateway = gateway(secret, &[&station.endpoint], &[]).await;

    let (status, response) = post(
        &gateway,
        &station.id(),
        Some(TOKEN),
        json!({"op": "deny", "args": {}, "context": context()}),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        response,
        json!({"ok": false, "error": {"code": "access_denied", "message": "tools.access is read"}})
    );
}

#[tokio::test]
async fn rejects_a_bad_token_before_contacting_the_station() {
    let secret = SecretKey::from_bytes(&rand::random());
    let station = fake_station(secret.public()).await;
    let gateway = gateway(secret, &[&station.endpoint], &[]).await;
    let body = json!({"op": "exec", "args": {"command": "true"}, "context": context()});

    let (status, response) = post(&gateway, &station.id(), Some("wrong-token"), body.clone()).await;
    assert_eq!(status, 401);
    assert_eq!(response["error"]["code"], "unauthorized");
    let (status, _) = post(&gateway, &station.id(), None, body).await;
    assert_eq!(status, 401);
    assert!(station.requests.lock().await.is_empty());
    assert_eq!(station.connections.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn rejects_malformed_requests() {
    let secret = SecretKey::from_bytes(&rand::random());
    let gateway = gateway(secret, &[], &[]).await;
    let (status, _) = post(
        &gateway,
        "not-a-station",
        Some(TOKEN),
        json!({"op": "exec", "context": context()}),
    )
    .await;
    assert_eq!(status, 400);
    let station = hex::encode([7u8; 32]);
    let (status, _) = post(
        &gateway,
        &station,
        Some(TOKEN),
        json!({"op": "exec", "context": "nope"}),
    )
    .await;
    assert_eq!(status, 400);
}

#[tokio::test]
async fn times_out_with_504_and_keeps_the_connection_usable() {
    let secret = SecretKey::from_bytes(&rand::random());
    let mut station = fake_station(secret.public()).await;
    let gateway = gateway(
        secret,
        &[&station.endpoint],
        &[("COMMA_STATION_REQUEST_TIMEOUT_MS", "500")],
    )
    .await;

    let (status, response) = post(
        &gateway,
        &station.id(),
        Some(TOKEN),
        json!({"op": "hang", "context": context()}),
    )
    .await;
    assert_eq!(status, 504);
    assert_eq!(response["error"]["code"], "timeout");
    // At its deadline the gateway stops the stream, not the connection.
    assert_eq!(station.hung.recv().await, Some(Ok(Some(0u32.into()))));

    let (status, _) = post(
        &gateway,
        &station.id(),
        Some(TOKEN),
        json!({"op": "fs.stat", "args": {"path": "/"}, "context": context()}),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(station.connections.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn unknown_station_is_unreachable() {
    let secret = SecretKey::from_bytes(&rand::random());
    let gateway = gateway(secret, &[], &[("COMMA_STATION_CONNECT_TIMEOUT_MS", "1000")]).await;
    let missing = hex::encode(SecretKey::from_bytes(&rand::random()).public().as_bytes());
    let (status, response) = post(
        &gateway,
        &missing,
        Some(TOKEN),
        json!({"op": "exec", "context": context()}),
    )
    .await;
    assert_eq!(status, 502);
    assert_eq!(response["error"]["code"], "station_unreachable");
}

#[tokio::test]
async fn station_that_does_not_admit_the_gateway_is_502() {
    let secret = SecretKey::from_bytes(&rand::random());
    let other_gateway = SecretKey::from_bytes(&rand::random()).public();
    let station = fake_station(other_gateway).await;
    let gateway = gateway(
        secret,
        &[&station.endpoint],
        &[("COMMA_STATION_REQUEST_TIMEOUT_MS", "3000")],
    )
    .await;
    let (status, response) = post(
        &gateway,
        &station.id(),
        Some(TOKEN),
        json!({"op": "exec", "context": context()}),
    )
    .await;
    assert_eq!(status, 502, "{response}");
    assert!(station.requests.lock().await.is_empty());
    drop(gateway.endpoint);
}

#[tokio::test]
async fn malformed_station_response_is_502() {
    let secret = SecretKey::from_bytes(&rand::random());
    let station = fake_station(secret.public()).await;
    let gateway = gateway(secret, &[&station.endpoint], &[]).await;
    let (status, response) = post(
        &gateway,
        &station.id(),
        Some(TOKEN),
        json!({"op": "garbage", "context": context()}),
    )
    .await;
    assert_eq!(status, 502);
    assert_eq!(response["error"]["code"], "bad_station_response");
}

#[tokio::test]
async fn deadline_before_anything_is_sent_is_unreachable_not_timeout() {
    let secret = SecretKey::from_bytes(&rand::random());
    let station = fake_station(secret.public()).await;
    let id = station.id();
    let gateway = gateway(
        secret,
        &[&station.endpoint],
        &[("COMMA_STATION_REQUEST_TIMEOUT_MS", "500")],
    )
    .await;
    // The station's address is known but nothing answers there any more, so
    // the dial is still pending when the request deadline passes.
    station.endpoint.close().await;

    let (status, response) = post(
        &gateway,
        &id,
        Some(TOKEN),
        json!({"op": "exec", "args": {"command": "true"}, "context": context()}),
    )
    .await;
    assert_eq!(status, 502, "{response}");
    assert_eq!(response["error"]["code"], "station_unreachable");
    assert!(station.requests.lock().await.is_empty());
}
