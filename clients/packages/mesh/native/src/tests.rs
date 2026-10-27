use super::*;
use std::sync::Condvar;

const ALPN: &[u8] = b"comma/test-echo/1";

/// The answers a mesh gave, by id, as the engine would queue them.
#[derive(Default)]
struct Answers {
    got: Mutex<Vec<(u64, String, String, Option<Vec<u8>>)>>,
    told: Condvar,
}

extern "C" fn complete(ctx: *mut c_void, id: u64, json: *const u8, jl: usize, e: *const u8, el: usize, b: *const u8, bl: usize, has: u8) {
    // SAFETY: the tests give the address of their `Answers`, which outlives the mesh.
    let answers = unsafe { &*(ctx as *const Answers) };
    let s = |p: *const u8, l: usize| if l == 0 { String::new() } else { String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(p, l) }).into_owned() };
    let bytes = (has != 0).then(|| if bl == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(b, bl) }.to_vec() });
    answers.got.lock().unwrap().push((id, s(json, jl), s(e, el), bytes));
    answers.told.notify_all();
}

impl Answers {
    /// The answer to `id`, once it comes: its JSON, its error, its bytes.
    fn to(&self, id: u64) -> (Value, String, Option<Vec<u8>>) {
        let mut got = self.got.lock().unwrap();
        loop {
            if let Some(i) = got.iter().position(|a| a.0 == id) {
                let (_, json, error, bytes) = got.remove(i);
                return (serde_json::from_str(&json).unwrap_or(Value::Null), error, bytes);
            }
            got = self.told.wait(got).unwrap();
        }
    }
}

/// A station on this machine that sends back what each stream brings, on no relay.
fn echo_station(runtime: &tokio::runtime::Runtime) -> (String, std::net::SocketAddr) {
    let endpoint = runtime.block_on(async {
        Endpoint::builder(Minimal).secret_key(SecretKey::from_bytes(&[7; 32])).alpns(vec![ALPN.to_vec()]).relay_mode(RelayMode::Disabled).bind().await.unwrap()
    });
    let id = hex::encode(endpoint.id().as_bytes());
    let port = endpoint.bound_sockets().iter().find(|a| a.is_ipv4()).unwrap().port();
    runtime.spawn(async move {
        while let Some(incoming) = endpoint.accept().await {
            let Ok(conn) = incoming.await else { continue };
            tokio::spawn(async move {
                while let Ok((mut send, mut recv)) = conn.accept_bi().await {
                    let bytes = recv.read_to_end(1 << 20).await.unwrap();
                    send.write_all(&bytes).await.unwrap();
                    send.finish().unwrap();
                }
            });
        }
    });
    (id, std::net::SocketAddr::from(([127, 0, 0, 1], port)))
}

#[test]
fn a_station_is_dialled_at_its_address_and_a_request_goes_both_ways_on_a_stream() {
    let station_runtime = tokio::runtime::Runtime::new().unwrap();
    let (station, at) = echo_station(&station_runtime);
    let answers = Answers::default();
    let mesh = Mesh::start(complete, &answers as *const Answers as *mut c_void).unwrap();
    let call = |id: u64, op: &str, args: Value, bytes: Option<&[u8]>| mesh.call(id, op.into(), args.to_string().as_bytes(), bytes.map(<[u8]>::to_vec));

    call(1, "mesh.bind", json!({ "relayUrls": [], "salixRelay": false }), Some(&[1; 32]));
    let (bound, error, _) = answers.to(1);
    assert_eq!(error, "");
    assert_eq!(bound["endpoint"], json!(hex::encode(SecretKey::from_bytes(&[1; 32]).public().as_bytes())));
    let endpoint = bound["id"].as_u64().unwrap();

    call(2, "mesh.connect", json!({ "id": endpoint, "addr": { "id": station, "ips": [at.to_string()] } }), Some(ALPN));
    let (connected, error, _) = answers.to(2);
    assert_eq!(error, "");
    assert_eq!(connected["remote"], json!(station));
    let conn = connected["id"].as_u64().unwrap();

    call(3, "mesh.nextVia", json!({ "id": conn, "last": null }), None);
    assert_eq!(answers.to(3).0, json!({ "via": "direct", "closed": false }));

    call(4, "mesh.openBi", json!({ "id": conn }), None);
    let stream = answers.to(4).0["id"].as_u64().unwrap();
    call(5, "mesh.write", json!({ "id": stream }), Some(b"hello"));
    assert_eq!(answers.to(5).1, "");
    call(6, "mesh.finish", json!({ "id": stream }), None);
    assert_eq!(answers.to(6).1, "");
    let mut echoed = Vec::new();
    for id in 7.. {
        call(id, "mesh.read", json!({ "id": stream }), None);
        let (json, error, bytes) = answers.to(id);
        assert_eq!(error, "");
        if json.get("end").is_some() {
            break;
        }
        echoed.extend(bytes.unwrap());
    }
    assert_eq!(echoed, b"hello");

    call(100, "mesh.close", json!({ "id": conn, "code": 0, "reason": "bye" }), None);
    assert_eq!(answers.to(100).1, "");
    call(101, "mesh.closed", json!({ "id": conn }), None);
    assert!(answers.to(101).0["reason"].is_string());
    call(102, "mesh.openBi", json!({ "id": conn }), None);
    assert_ne!(answers.to(102).1, "");
    call(103, "mesh.nextVia", json!({ "id": conn, "last": "direct" }), None);
    assert_eq!(answers.to(103).0["closed"], json!(true));

    call(104, "mesh.endpointClose", json!({ "id": endpoint }), None);
    assert_eq!(answers.to(104).1, "");
    drop(mesh);
}

#[test]
fn an_operation_on_no_handle_fails_and_is_answered() {
    let answers = Answers::default();
    let mesh = Mesh::start(complete, &answers as *const Answers as *mut c_void).unwrap();
    mesh.call(1, "mesh.openBi".into(), br#"{"id":999}"#, None);
    assert_eq!(answers.to(1).1, "no handle 999");
    mesh.call(2, "mesh.nothing".into(), b"{}", None);
    assert_eq!(answers.to(2).1, "no operation mesh.nothing");
}
