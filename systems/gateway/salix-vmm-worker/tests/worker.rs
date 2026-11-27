//! The worker between a scripted Salix (its stdio parent) and a test Host,
//! over the real transports: TLS 1.3 + yamux for the Host, a Unix socket for
//! Salix's session calls, QUIC for iroh tunnels.

use base64::{Engine, engine::general_purpose::STANDARD};
use prost::Message;
use salix_vmm_worker::{
    Config,
    control::{read_packet, write_packet},
    pb::{
        self,
        remote::{
            self, ControllerCommand, EnsureAllocation, OpenSession, connect_request,
            controller_command::Command,
        },
        trust,
    },
    status::{Code, Status},
    testing::{self, Event, Host, HostConfig},
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    sync::Notify,
};
use tokio_util::sync::CancellationToken;

const CREDENTIAL: &[u8] = b"0123456789abcdef0123456789abcdef";
const REGISTRATION: &str = "registration-1";
/// Above 2^53: a connection epoch never fits a JSON number.
const EPOCH: u64 = 9_007_199_254_740_993;

type Handler = dyn Fn(&str, &Value) -> Option<(u16, Value)> + Send + Sync;

/// The test's Salix: it answers the worker's control calls and records them.
#[derive(Default)]
struct Salix {
    calls: Mutex<Vec<(String, Value)>>,
    events: Mutex<Vec<Value>>,
    commands: Mutex<VecDeque<ControllerCommand>>,
    changed: Notify,
}

impl Salix {
    fn answer(&self, op: &str, _body: &Value) -> (u16, Value) {
        match op {
            "claim_command" => match self.commands.lock().unwrap().pop_front() {
                Some(command) => (200, json!({"command_json": pb::to_json(&command).unwrap()})),
                None => (204, Value::Null),
            },
            _ => (200, Value::Null),
        }
    }

    fn calls(&self, op: &str) -> Vec<Value> {
        let calls = self.calls.lock().unwrap();
        calls
            .iter()
            .filter(|(name, _)| name == op)
            .map(|(_, body)| body.clone())
            .collect()
    }

    /// Waits until `ready` finds what it looks for among the recorded calls and events.
    async fn wait<T>(&self, mut ready: impl FnMut(&Salix) -> Option<T>) -> T {
        loop {
            let changed = self.changed.notified();
            if let Some(found) = ready(self) {
                return found;
            }
            changed.await;
        }
    }

    async fn call(&self, op: &str, index: usize) -> Value {
        self.wait(|salix| salix.calls(op).get(index).cloned()).await
    }
}

struct Harness {
    _directory: tempfile::TempDir,
    addr: String,
    certificate: String,
    socket: PathBuf,
    token: String,
    salix: Arc<Salix>,
    shutdown: CancellationToken,
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

fn decode(encoded: &Value) -> Value {
    serde_json::from_slice(&STANDARD.decode(encoded.as_str().unwrap()).unwrap()).unwrap()
}

async fn start(handler: Option<Arc<Handler>>) -> Harness {
    let directory = tempfile::tempdir().unwrap();
    let (certificate, key) = testing::generate_certificate();
    std::fs::write(directory.path().join("tls.crt"), &certificate).unwrap();
    std::fs::write(directory.path().join("tls.key"), key).unwrap();
    let socket = directory.path().join("worker.sock");
    let token = "t".repeat(43);
    let config: Config = serde_json::from_value(json!({
        "instance_id": "comma-0",
        "remote_listen": "127.0.0.1:0",
        "tls_cert_file": directory.path().join("tls.crt"),
        "tls_key_file": directory.path().join("tls.key"),
        "socket": socket,
        "token": token,
        "iroh_preset": "minimal",
    }))
    .unwrap();

    let (worker_end, salix_end) = tokio::io::duplex(1 << 20);
    let (worker_read, worker_write) = tokio::io::split(worker_end);
    let (mut read, mut write) = tokio::io::split(salix_end);
    let shutdown = CancellationToken::new();
    tokio::spawn(salix_vmm_worker::run(
        config,
        worker_read,
        worker_write,
        shutdown.clone(),
    ));

    let ready: Value =
        serde_json::from_slice(&read_packet(&mut read).await.unwrap().unwrap()).unwrap();
    assert_eq!(ready["type"], "ready");
    let addr = ready["remote_addr"].as_str().unwrap().to_owned();

    let salix = Arc::new(Salix::default());
    let recorder = salix.clone();
    tokio::spawn(async move {
        while let Ok(Some(packet)) = read_packet(&mut read).await {
            let frame: Value = serde_json::from_slice(&packet).unwrap();
            if frame["type"] == "event" {
                recorder.events.lock().unwrap().push(frame);
                recorder.changed.notify_waiters();
                continue;
            }
            let op = frame["op"].as_str().unwrap();
            let (status, body) = handler
                .as_ref()
                .and_then(|handler| handler(op, &frame["body"]))
                .unwrap_or_else(|| recorder.answer(op, &frame["body"]));
            recorder
                .calls
                .lock()
                .unwrap()
                .push((op.to_owned(), frame["body"].clone()));
            recorder.changed.notify_waiters();
            let reply = json!({"type": "reply", "id": frame["id"], "status": status, "body": body});
            write_packet(&mut write, reply.to_string().as_bytes())
                .await
                .unwrap();
        }
    });
    Harness {
        _directory: directory,
        addr,
        certificate,
        socket,
        token,
        salix,
        shutdown,
    }
}

impl Harness {
    async fn host(&self, epoch: u64) -> Host {
        self.host_with(HostConfig::new(REGISTRATION, CREDENTIAL, epoch))
            .await
    }

    async fn host_with(&self, config: HostConfig) -> Host {
        Host::start(&self.addr, self.certificate.as_bytes(), config)
            .await
            .unwrap()
    }

    fn queue(&self, command_id: &str, command: Command) {
        self.salix
            .commands
            .lock()
            .unwrap()
            .push_back(ControllerCommand {
                command_id: command_id.into(),
                timeout_millis: 5_000,
                target_revision: 1,
                command: Some(command),
                ..Default::default()
            });
    }

    /// Opens a session for `allocation` and waits until Salix has observed it.
    async fn open_session(&self, allocation: &str, generation: u64) {
        let observed = self.salix.calls("observe_session").len();
        self.queue(
            &format!("open-{allocation}-{generation}-{observed}"),
            Command::OpenSession(OpenSession {
                allocation_id: allocation.into(),
                allocation_generation: generation,
                execution_owner_id: "owner".into(),
            }),
        );
        self.salix.call("observe_session", observed).await;
    }

    async fn local(&self, request: Value) -> UnixStream {
        let mut stream = UnixStream::connect(&self.socket).await.unwrap();
        write_packet(&mut stream, request.to_string().as_bytes())
            .await
            .unwrap();
        stream
    }

    async fn request(&self, request: Value) -> (u16, Value) {
        let mut stream = self.local(request).await;
        let reply = read_packet(&mut stream).await.unwrap().unwrap();
        let reply: Value = serde_json::from_slice(&reply).unwrap();
        (
            reply["status"].as_u64().unwrap() as u16,
            reply["body"].clone(),
        )
    }

    fn session(&self, allocation: &str, generation: u64, epoch: u64) -> Value {
        json!({
            "registration_id": REGISTRATION, "allocation_id": allocation,
            "allocation_generation": generation, "connection_epoch": epoch.to_string(),
        })
    }

    async fn operation(&self, allocation: &str, operation: &str, args: Value) -> (u16, Value) {
        self.request(json!({
            "token": self.token, "op": "session_call", "operation": operation, "args": args,
            "session": self.session(allocation, 3, EPOCH),
        }))
        .await
    }

    async fn import(&self, session: Value, request_id: &str) -> (u16, Value) {
        let digest = "a".repeat(64);
        let archive = "b".repeat(64);
        self.request(json!({
            "token": self.token, "op": "session_call", "operation": "compute.image.import",
            "session": session,
            "headers": {
                "x-comma-import-request-id": request_id,
                "x-comma-image-reference": format!("comma.local/runtime/shell@sha256:{digest}"),
                "x-comma-archive-size": "1024",
                "x-comma-archive-sha256": archive,
                "x-comma-archive-url": format!("https://cdn.example/runtime-bundles/sha256/{archive}.oci.tar"),
                "x-comma-manifest-digest": format!("sha256:{digest}"),
                "x-comma-platform": "linux/arm64",
            },
        }))
        .await
    }
}

fn b64(bytes: impl AsRef<[u8]>) -> String {
    STANDARD.encode(bytes)
}

async fn ended(host: &mut Host) -> Status {
    host.until(|event| match event {
        Event::Ended(status) => Some(status.clone()),
        _ => None,
    })
    .await
}

async fn ready(host: &mut Host) -> remote::ControllerReady {
    host.until(|event| match event {
        Event::Ready(ready) => Some(ready.clone()),
        Event::Ended(status) => panic!("the connection ended: {status:?}"),
        _ => None,
    })
    .await
}

async fn runtime_call(host: &mut Host, wanted: &str) -> (Vec<(String, String)>, Value) {
    host.until(|event| match event {
        Event::Runtime {
            method,
            metadata,
            request,
        } if method == wanted => Some((metadata.clone(), request.clone())),
        _ => None,
    })
    .await
}

#[tokio::test(flavor = "multi_thread")]
async fn a_host_connects_opens_a_session_and_serves_typed_operations() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    let acknowledged = ready(&mut host).await;
    assert_eq!(acknowledged.registration_id, REGISTRATION);
    assert_eq!(acknowledged.connection_epoch, EPOCH);
    assert_eq!(acknowledged.acknowledged_inventory_watermark, 1);
    assert_eq!(acknowledged.enabled_features, ["remote-observation-v1"]);

    // Salix authenticated the credential and observed the exact hello before readiness.
    let authenticate = harness.salix.call("authenticate", 0).await;
    assert_eq!(
        authenticate,
        json!({"registration_id": REGISTRATION, "credential_b64": b64(CREDENTIAL)})
    );
    let hello = decode(&harness.salix.call("observe_hello", 0).await["hello_b64"]);
    assert_eq!(hello["protocolVersion"], "5");
    assert_eq!(hello["registrationId"], REGISTRATION);
    assert_eq!(hello["connectionEpoch"], EPOCH.to_string());
    assert_eq!(hello["inventoryWatermark"], "1");
    assert_eq!(hello["observation"]["sequence"], "1");
    assert!(hello["observation"]["observedUnixMillis"].is_string());

    harness.open_session("allocation-1", 3).await;
    // The command result commits before Salix is told of the session it proves.
    let order: Vec<String> = harness
        .salix
        .calls
        .lock()
        .unwrap()
        .iter()
        .map(|(op, _)| op.clone())
        .collect();
    let position = |op: &str| order.iter().position(|name| name == op).unwrap();
    assert!(position("authenticate") < position("observe_hello"));
    assert!(position("observe_hello") < position("claim_command"));
    assert!(position("commit_result") < position("observe_session"));

    let commit = harness.salix.call("commit_result", 0).await;
    assert_eq!(commit["registration_id"], REGISTRATION);
    let transcript = &commit["transcript"];
    assert_eq!(
        transcript["ack"]["disposition"],
        "COMMAND_ACK_DISPOSITION_ADMITTED"
    );
    assert_eq!(transcript["ack"]["connectionEpoch"], EPOCH.to_string());
    assert_eq!(transcript["result"]["outcome"], "COMMAND_OUTCOME_SUCCEEDED");
    assert_eq!(
        transcript["result"]["sessionReady"]["allocationId"],
        "allocation-1"
    );
    assert_eq!(
        transcript["result"]["sessionReady"]["allocationGeneration"],
        "3"
    );
    assert_eq!(transcript["evidence"][0]["stage"], 1);
    assert_eq!(transcript["evidence"][0]["connection_epoch"], EPOCH);
    let nonce = transcript["result"]["sessionReady"]["tunnelNonce"]
        .as_str()
        .unwrap()
        .to_owned();
    let header = decode(&harness.salix.call("observe_session", 0).await["header_b64"]);
    assert_eq!(
        header,
        json!({
            "registrationId": REGISTRATION, "allocationId": "allocation-1",
            "allocationGeneration": "3", "tunnelNonce": nonce,
            "connectionEpoch": EPOCH.to_string(),
            "expiresUnixMillis": transcript["result"]["sessionReady"]["expiresUnixMillis"],
        })
    );

    // compute.exec runs in the one running container, under the session's capability.
    let (status, result) = harness
        .operation(
            "allocation-1",
            "compute.exec",
            json!({
                "command": ["echo", "hi"], "env": ["A=1"], "request_id": "r1",
                "stdin_base64": b64("!"), "workdir": "/work",
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        result,
        json!({
            "stdout_base64": b64("hi!"),
            "stderr_base64": b64("warn"),
            "exit_code": 0,
            "timed_out": false,
            "oom_killed": false,
        })
    );
    let (metadata, start) = runtime_call(&mut host, "Exec").await;
    assert_eq!(
        metadata,
        [
            (
                "x-agentvmm-allocation-id".to_owned(),
                "allocation-1".to_owned()
            ),
            (
                "x-agentvmm-allocation-generation".to_owned(),
                "3".to_owned()
            ),
            ("authorization".to_owned(), format!("Bearer {nonce}")),
        ]
    );
    assert_eq!(start["container_id"], "workload");
    assert_eq!(start["expected_instance_id"], "instance-1");
    assert_eq!(start["execution_id"], "exec:r1");
    assert_eq!(start["execution_kind"], "EXECUTION_KIND_EXEC");
    assert_eq!(start["argv"], json!(["echo", "hi"]));
    assert_eq!(start["env"], json!(["A=1"]));
    assert_eq!(start["workdir"], "/work");
    assert_eq!(start["timeout_ms"], "60000");
    assert!(
        start["execution_deadline_unix_nano"]
            .as_str()
            .unwrap()
            .parse::<i64>()
            .unwrap()
            > 0
    );

    // A caller cannot retarget an exec at another container.
    let (status, error) = harness
        .operation(
            "allocation-1",
            "compute.container.exec",
            json!({
                "argv": ["echo"], "request_id": "r2", "container_id": "other",
            }),
        )
        .await;
    assert_eq!(
        (status, error["code"].as_str()),
        (502, Some("runtime_failed"))
    );

    // Messages larger than the socket buffers pass in both directions at once.
    let large = vec![b'z'; 3 << 20];
    let (status, result) = harness
        .operation(
            "allocation-1",
            "compute.exec",
            json!({
                "command": ["echo"], "request_id": "r3", "stdin_base64": b64(&large),
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        STANDARD
            .decode(result["stdout_base64"].as_str().unwrap())
            .unwrap(),
        large
    );
    let (status, error) = harness
        .operation(
            "allocation-1",
            "compute.exec",
            json!({
                "command": ["flood", (9 << 20).to_string()], "request_id": "r4",
            }),
        )
        .await;
    assert_eq!(
        (status, error["code"].as_str()),
        (502, Some("runtime_failed"))
    );

    let (status, read) = harness
        .operation(
            "allocation-1",
            "compute.workspace.read",
            json!({"path": "notes.txt"}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        read,
        json!({"content_base64": b64("hello world"), "sha256": b64([9u8; 32])})
    );
    let (_, request) = runtime_call(&mut host, "ReadWorkspace").await;
    assert_eq!(
        request,
        json!({"path": "notes.txt", "max_bytes": "1048576"})
    );

    let (status, written) = harness
        .operation(
            "allocation-1",
            "compute.workspace.write",
            json!({
                "path": "out.txt", "content_base64": b64(vec![b'x'; 200_000]), "expected_prefix_sha256": "",
                "request_id": "w1",
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        written,
        json!({"entry": {"path": "out.txt", "size": "200000", "mode": 420}, "sha256": b64([7u8; 32])})
    );
    // A Host that refuses a write stops reading it. Its decision is the answer:
    // the rest of the request does not wait for stream window until the deadline.
    let (status, error) = harness
        .operation(
            "allocation-1",
            "compute.workspace.write",
            json!({
                "path": "out.txt", "volume_id": "full", "content_base64": b64(vec![b'x'; 1 << 20]),
                "expected_prefix_sha256": "", "request_id": "w2",
            }),
        )
        .await;
    assert_eq!(
        (status, error["code"].as_str()),
        (429, Some("resource_exhausted"))
    );

    let (status, logs) = harness
        .operation(
            "allocation-1",
            "compute.container.logs",
            json!({"container_id": "workload", "limit": 2}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(logs["records"].as_array().unwrap().len(), 2);
    assert_eq!(logs["records"][1]["cursor"], "cursor-1");

    let (status, forwarded) = harness
        .operation(
            "allocation-1",
            "compute.forward.tcp",
            json!({
                "container_id": "workload", "container_instance_id": "instance-1", "port": 8080,
                "data_base64": b64("GET /"),
            }),
        )
        .await;
    assert_eq!(
        (status, forwarded),
        (200, json!({"data_base64": b64("GET /")}))
    );

    let (status, acquired) = harness
        .operation("allocation-1", "compute.execution.acquire", json!({
            "execution_id": "main", "kind": "auth_operation", "deadline_unix_nano": "1234567890123456789",
            "container_id": "workload", "expected_instance_id": "instance-1",
        }))
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        acquired,
        json!({"execution_id": "main", "container_instance_id": "instance-1", "acquired": true})
    );
    let (_, request) = runtime_call(&mut host, "AcquireExecution").await;
    assert_eq!(request["deadline_unix_nano"], "1234567890123456789");
    assert_eq!(request["kind"], "EXECUTION_KIND_AUTH_OPERATION");

    // Host decisions keep their finite code; Host text never crosses.
    let (status, error) = harness
        .operation(
            "allocation-1",
            "compute.container.start",
            json!({"container_id": "stale"}),
        )
        .await;
    assert_eq!(status, 409);
    assert_eq!(
        error,
        json!({
            "code": "stale_container_instance", "stage": "container_start", "resource": "runtime",
            "message": "Runtime operation was rejected.",
        })
    );
    let (status, error) = harness
        .operation(
            "allocation-1",
            "compute.execution.acquire",
            json!({"execution_id": "busy"}),
        )
        .await;
    assert_eq!(
        (status, error["code"].as_str()),
        (429, Some("workload_execution_busy"))
    );
    let (status, error) = harness
        .operation("allocation-1", "compute.volume.list", json!({}))
        .await;
    assert_eq!(
        (status, error["code"].as_str()),
        (502, Some("runtime_failed"))
    );

    // Only the exact fenced session, a known operation and the node's token are served.
    assert_eq!(
        harness
            .operation("allocation-1", "environment_get", json!({}))
            .await,
        (404, Value::Null)
    );
    let mut other = harness.session("allocation-1", 4, EPOCH);
    let call = |session: Value, token: &str| json!({"token": token, "op": "session_call", "operation": "compute.image.list", "args": {}, "session": session});
    assert_eq!(
        harness.request(call(other.clone(), &harness.token)).await,
        (404, Value::Null)
    );
    other["allocation_generation"] = json!(3);
    assert_eq!(
        harness.request(call(other.clone(), &harness.token)).await.0,
        200
    );
    assert_eq!(harness.request(call(other.clone(), "wrong")).await.0, 401);
    other["connection_epoch"] = json!((EPOCH + 1).to_string());
    assert_eq!(
        harness.request(call(other, &harness.token)).await,
        (404, Value::Null)
    );

    // Losing the Host connection ends its sessions and tells Salix which connection ended.
    host.close();
    let disconnected = harness.salix.call("disconnected", 0).await;
    assert_eq!(
        disconnected,
        json!({"registration_id": REGISTRATION, "connection_epoch": EPOCH.to_string()})
    );
    assert_eq!(
        harness
            .operation("allocation-1", "compute.image.list", json!({}))
            .await,
        (404, Value::Null)
    );
    let stats = harness
        .salix
        .wait(|salix| {
            let events = salix.events.lock().unwrap();
            events
                .iter()
                .rev()
                .find(|event| event["event"] == "stats")
                .cloned()
                .filter(|stats| stats["connections"] == 0)
        })
        .await;
    assert_eq!(stats["sessions"], 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_process_start_is_idempotent_by_request_id() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;
    let start = json!({"command": ["serve"], "request_id": "p1", "env": ["A=1"]});

    let (status, started) = harness
        .operation("allocation-1", "process.start", start.clone())
        .await;
    assert_eq!(
        (status, started.clone()),
        (
            200,
            json!({"process_id": "process-request-p1", "state": "running"})
        )
    );
    let (_, request) = runtime_call(&mut host, "Exec").await;
    assert_eq!(request["execution_id"], "process:process-request-p1");
    assert_eq!(request["execution_kind"], "EXECUTION_KIND_PROCESS");
    assert_eq!(request["request_id"], "p1");
    assert_eq!(request["expected_instance_id"], "instance-1");

    // The same request names the same process and starts nothing; other arguments are refused.
    assert_eq!(
        harness
            .operation("allocation-1", "process.start", start)
            .await,
        (200, started)
    );
    let reused = json!({"command": ["serve"], "request_id": "p1", "env": ["A=2"]});
    assert_eq!(
        harness
            .operation("allocation-1", "process.start", reused)
            .await
            .0,
        502
    );
    let targeted = json!({"command": ["serve"], "request_id": "p2", "container_id": "other"});
    assert_eq!(
        harness
            .operation("allocation-1", "process.start", targeted)
            .await
            .0,
        502
    );
    let (_, listed) = harness
        .operation("allocation-1", "process.list", json!({}))
        .await;
    assert_eq!(
        listed,
        json!({"processes": [{"process_id": "process-request-p1", "state": "running"}]})
    );

    // The worker buffers output as it arrives: ask until it holds what the Host sent.
    let tail = |done: fn(&Value) -> bool| {
        let harness = &harness;
        async move {
            loop {
                let (status, tail) = harness
                    .operation(
                        "allocation-1",
                        "process.tail",
                        json!({"process_id": "process-request-p1"}),
                    )
                    .await;
                assert_eq!(status, 200);
                if done(&tail) {
                    return tail;
                }
                tokio::task::yield_now().await;
            }
        }
    };
    tail(|tail| tail["stdout_base64"] == b64("ready\n")).await;
    let write = json!({"process_id": "process-request-p1", "data_base64": b64("ping")});
    assert_eq!(
        harness
            .operation("allocation-1", "process.write", write.clone())
            .await,
        (200, json!({"written_bytes": 4}))
    );
    tail(|tail| tail["stdout_base64"] == b64("ready\nping")).await;

    let stop = |signal: &str| json!({"process_id": "process-request-p1", "signal": signal});
    assert_eq!(
        harness
            .operation("allocation-1", "process.stop", stop("HUP"))
            .await
            .0,
        502
    );
    let (status, _) = harness
        .operation("allocation-1", "process.stop", stop("int"))
        .await;
    assert_eq!(status, 200);
    let exited = tail(|tail| tail["state"] == "exited").await;
    assert_eq!(exited["exit_code"], 130);
    assert_eq!(
        harness
            .operation("allocation-1", "process.write", write)
            .await
            .0,
        502
    );
    assert_eq!(
        harness
            .operation(
                "allocation-1",
                "process.tail",
                json!({"process_id": "none"})
            )
            .await
            .0,
        502
    );

    // A replacement session starts with no processes: the old carrier's are unknown, not gone.
    harness.open_session("allocation-1", 3).await;
    let (_, listed) = harness
        .operation("allocation-1", "process.list", json!({}))
        .await;
    assert_eq!(listed, json!({"processes": []}));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_image_import_answers_in_the_bounded_vocabulary() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;
    let session = harness.session("allocation-1", 3, EPOCH);
    let digest = format!("sha256:{}", "a".repeat(64));

    let (status, image) = harness.import(session.clone(), "import-1").await;
    assert_eq!(status, 200);
    assert_eq!(
        image,
        json!({
            "reference": format!("comma.local/runtime/shell@{digest}"), "digest": digest,
            "platform": "linux/arm64", "logical_bytes": 1024, "generation_id": "generation-1",
        })
    );
    let (_, header) = runtime_call(&mut host, "ImportImage").await;
    assert_eq!(header["request_id"], "import-1");
    assert_eq!(header["archive_sha256"], b64([0xbbu8; 32]));
    assert_eq!(header["archive_size"], "1024");
    assert!(
        header["archive_url"]
            .as_str()
            .unwrap()
            .starts_with("https://cdn.example/")
    );

    let (status, error) = harness.import(session.clone(), "full-1").await;
    assert_eq!(status, 429);
    assert_eq!(
        error,
        json!({
            "code": "resource_capacity_exhausted", "stage": "import_admission",
            "resource": "storage_headroom", "message": "Guest storage headroom is unavailable.",
            "available_bytes": 1024, "required_bytes": 4096,
        })
    );
    let (status, error) = harness.import(session.clone(), "busy-1").await;
    assert_eq!(status, 429);
    assert_eq!(
        error,
        json!({
            "code": "resource_capacity_exhausted", "stage": "import_slot", "resource": "import_slot",
            "message": "Guest OCI import slot is occupied.",
        })
    );
    // The Host stored something other than the committed manifest.
    let (status, error) = harness.import(session.clone(), "mismatch-1").await;
    assert_eq!(status, 502);
    assert_eq!(
        error,
        json!({
            "code": "image_import_failed", "stage": "image_import", "resource": "image",
            "message": "Imported image validation failed.",
        })
    );
    let (status, error) = harness.import(session.clone(), "-invalid").await;
    assert_eq!(
        (status, error["code"].as_str(), error["resource"].as_str()),
        (400, Some("invalid_argument"), Some("image"))
    );
    let (status, error) = harness
        .import(harness.session("allocation-2", 3, EPOCH), "import-2")
        .await;
    assert_eq!(status, 404);
    assert_eq!(
        error,
        json!({
            "code": "stale_session", "stage": "image_import", "resource": "runtime",
            "message": "Image import session is unavailable.",
        })
    );

    let outcomes = harness
        .salix
        .wait(|salix| {
            let events = salix.events.lock().unwrap();
            let imports: Vec<Value> = events
                .iter()
                .filter(|event| event["event"] == "image_import")
                .cloned()
                .collect();
            (imports.len() == 6).then_some(imports)
        })
        .await;
    assert_eq!(
        (
            outcomes[0]["outcome"].as_str(),
            outcomes[0]["bytes"].as_u64()
        ),
        (Some("success"), Some(1024))
    );
    assert!(
        outcomes[1..]
            .iter()
            .all(|event| event["outcome"] == "failure" && event["bytes"] == 0)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refused_host_learns_why_and_nothing_else_runs() {
    let refuse: Arc<Handler> = Arc::new(|op, body| match (op, body["registration_id"].as_str()) {
        ("authenticate", Some("rejected")) => {
            Some((401, json!({"error": "registration_credential_rejected"})))
        }
        ("authenticate", Some("outage")) => Some((
            503,
            json!({"error": "registration_authentication_unavailable"}),
        )),
        ("observe_hello", _) => {
            let hello = decode(&body["hello_b64"]);
            match hello["registrationId"].as_str() {
                Some("inactive") => Some((403, json!({"error": "registration_inactive"}))),
                Some("malformed") => Some((422, json!({"error": "invalid_observation"}))),
                _ => None,
            }
        }
        _ => None,
    });
    let harness = start(Some(refuse)).await;
    let refused = |registration: &'static str| {
        let harness = &harness;
        async move {
            let mut host = harness
                .host_with(HostConfig::new(registration, CREDENTIAL, EPOCH))
                .await;
            ended(&mut host).await
        }
    };

    // Only an authoritative refusal stops the Host; an outage is an ordinary reconnect.
    let status = refused("rejected").await;
    assert_eq!(
        (status.code, status.message.as_str()),
        (Code::Unauthenticated, "registration credential rejected")
    );
    assert_eq!(refused("outage").await.code, Code::Unavailable);
    let status = refused("inactive").await;
    assert_eq!(
        (status.code, status.message.as_str()),
        (Code::PermissionDenied, "registration_inactive")
    );
    assert_eq!(refused("malformed").await.code, Code::Unavailable);

    // Another protocol is refused with the supported range, before Salix observes anything.
    let mut config = HostConfig::new("old", CREDENTIAL, EPOCH);
    config.protocol_version = "4".into();
    let status = ended(&mut harness.host_with(config).await).await;
    assert_eq!(status.code, Code::FailedPrecondition);
    let info = &status.error_infos()[0];
    assert_eq!(info.reason, "REMOTE_PROTOCOL_UNSUPPORTED");
    assert_eq!(info.metadata["host_protocol"], "4");
    assert_eq!(info.metadata["max_protocol"], "5");
    let observed = harness.salix.calls("observe_hello");
    assert!(
        observed
            .iter()
            .all(|body| decode(&body["hello_b64"])["registrationId"] != "old")
    );

    // The former registration metadata key still names the Host.
    let mut config = HostConfig::new(REGISTRATION, CREDENTIAL, EPOCH);
    config.registration_header = "x-agent-vmm-registration".into();
    let mut host = harness.host_with(config).await;
    ready(&mut host).await;
    // A second connection claiming the epoch this worker already holds is stale.
    let status = ended(&mut harness.host(EPOCH).await).await;
    assert_eq!(
        (status.code, status.message.as_str()),
        (Code::Aborted, "stale connection epoch")
    );

    // Without an identity no control call is made; retired and unknown methods are not served.
    let (mux, _inbound) = testing::dial(&harness.addr, "localhost", harness.certificate.as_bytes())
        .await
        .unwrap();
    let authenticated = harness.salix.calls("authenticate").len();
    let anonymous = testing::unary::<_, remote::ConnectResponse>(
        &mux,
        testing::CONNECT,
        vec![],
        &remote::ConnectRequest::default(),
    )
    .await;
    assert_eq!(anonymous.unwrap_err().code, Code::Unauthenticated);
    assert_eq!(harness.salix.calls("authenticate").len(), authenticated);
    let identity = testing::identity("x-agentvmm-registration-id", REGISTRATION, CREDENTIAL);
    for method in [
        "/agentvmm.remote.v1.RemoteControllerService/ServeSession",
        "/agentvmm.remote.v1.RemoteControllerService/Enroll",
        "/agentvmm.host.v1.AgentRuntimeService/Exec",
    ] {
        let answer = testing::unary::<_, remote::ConnectResponse>(
            &mux,
            method,
            identity.clone(),
            &remote::ConnectRequest::default(),
        )
        .await;
        assert_eq!(answer.unwrap_err().code, Code::Unimplemented, "{method}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn claims_survive_control_outages_and_inventory_changes_force_a_fresh_hello() {
    let outages = Arc::new(Mutex::new(2));
    let stale = Arc::new(Mutex::new(false));
    let (remaining, fenced) = (outages.clone(), stale.clone());
    let handler: Arc<Handler> = Arc::new(move |op, _| {
        if op != "claim_command" {
            return None;
        }
        let mut remaining = remaining.lock().unwrap();
        if *remaining > 0 {
            *remaining -= 1;
            return Some((503, json!({"error": "control_unavailable"})));
        }
        fenced
            .lock()
            .unwrap()
            .then(|| (409, json!({"error": "stale_connection"})))
    });
    let harness = start(Some(handler)).await;
    let ensure = |allocation: &str| {
        Command::EnsureAllocation(EnsureAllocation {
            allocation_id: allocation.into(),
            policy_revision: 4,
            generation: 2,
            ..Default::default()
        })
    };

    // Two unavailable claims do not cost the Host its connection.
    harness.queue("ensure-1", ensure("allocation-1"));
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    let commit = harness.salix.call("commit_result", 0).await;
    assert_eq!(
        commit["transcript"]["result"]["allocation"]["revision"],
        "4"
    );
    assert_eq!(commit["transcript"]["result"]["inventoryWatermark"], "2");
    // The ensure changed the Host's inventory: the connection ends cleanly for a fresh hello.
    assert_eq!(ended(&mut host).await, Status::ok());
    harness.salix.call("disconnected", 0).await;

    // An ensure refused before any mutation keeps the connection for the next command.
    harness.queue("ensure-2", ensure("full-1"));
    let mut host = harness.host(EPOCH + 1).await;
    ready(&mut host).await;
    let commit = harness.salix.call("commit_result", 1).await;
    assert_eq!(
        commit["transcript"]["result"]["outcome"],
        "COMMAND_OUTCOME_REJECTED"
    );
    assert_eq!(
        commit["transcript"]["result"]["reason"],
        "ERROR_REASON_CAPACITY_EXHAUSTED"
    );
    assert!(commit["transcript"].get("evidence").is_none());
    harness.open_session("allocation-1", 2).await;

    // A claim Salix fences as stale is not retried.
    *stale.lock().unwrap() = true;
    let status = ended(&mut host).await;
    assert_eq!(
        (status.code, status.message.as_str()),
        (Code::Unavailable, "control claim failed")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn observation_renewals_are_settled_and_a_replacement_keeps_its_own_epoch() {
    // As Salix does, hand commands only to the connection observed last.
    let current = Arc::new(Mutex::new(Value::Null));
    let observed = current.clone();
    let handler: Arc<Handler> = Arc::new(move |op, body| match op {
        "observe_hello" => {
            *observed.lock().unwrap() = decode(&body["hello_b64"])["connectionEpoch"].clone();
            None
        }
        "claim_command" if body["connection_epoch"] != *observed.lock().unwrap() => {
            Some((409, json!({"error": "stale_connection"})))
        }
        _ => None,
    });
    let harness = start(Some(handler)).await;
    let mut first = harness.host(EPOCH).await;
    ready(&mut first).await;
    first.send(connect_request::Payload::ObservationRenewal(
        remote::RemoteObservationRenewal {
            connection_epoch: EPOCH,
            observation: Some(testing::observation(2)),
        },
    ));
    let settled = harness.salix.call("settle_observation", 0).await;
    assert_eq!(settled["registration_id"], REGISTRATION);
    let renewal = decode(&settled["renewal_b64"]);
    assert_eq!(renewal["connectionEpoch"], EPOCH.to_string());
    assert_eq!(renewal["observation"]["sequence"], "2");

    // A reconnect under a new epoch replaces the old connection: its next claim
    // is stale, and it ends reporting its own epoch.
    let mut second = harness.host(EPOCH + 1).await;
    ready(&mut second).await;
    let status = ended(&mut first).await;
    assert_eq!(
        (status.code, status.message.as_str()),
        (Code::Unavailable, "control claim failed")
    );
    let disconnected = harness.salix.call("disconnected", 0).await;
    assert_eq!(disconnected["connection_epoch"], EPOCH.to_string());

    // The replacement is this registration's connection here, and holds its sessions.
    harness.open_session("allocation-1", 3).await;
    let key = harness.session("allocation-1", 3, EPOCH + 1);
    let list = json!({
        "token": harness.token, "op": "session_call", "operation": "compute.image.list",
        "args": {}, "session": key,
    });
    assert_eq!(harness.request(list.clone()).await.0, 200);
    // Salix is told what this node holds: one connection and its one session.
    harness
        .salix
        .wait(|salix| {
            let events = salix.events.lock().unwrap();
            let latest = events
                .iter()
                .rev()
                .find(|event| event["event"] == "stats")?;
            (latest["connections"] == 1 && latest["sessions"] == 1).then_some(())
        })
        .await;

    // A renewal for another connection breaks the protocol: the stream ends, and its sessions with it.
    second.send(connect_request::Payload::ObservationRenewal(
        remote::RemoteObservationRenewal {
            connection_epoch: EPOCH + 7,
            observation: Some(testing::observation(3)),
        },
    ));
    assert_eq!(ended(&mut second).await.code, Code::Unavailable);
    let disconnected = harness.salix.call("disconnected", 1).await;
    assert_eq!(disconnected["connection_epoch"], (EPOCH + 1).to_string());
    assert_eq!(harness.request(list).await, (404, Value::Null));
    assert_eq!(harness.salix.calls("settle_observation").len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn registry_calls_carry_the_typed_request_and_the_signed_response() {
    let snapshot = trust::GetSnapshotResponse {
        snapshot: Some(trust::MeshSnapshot {
            mesh_id: "mesh-1".into(),
            revision: 12,
            snapshot_digest: vec![5; 32],
            ..Default::default()
        }),
    };
    let signed = snapshot.encode_to_vec();
    let handler: Arc<Handler> = Arc::new(move |op, body| match op {
        "authenticate" if body["registration_id"] == "rejected" => Some((401, Value::Null)),
        "registry_snapshot" => Some((200, json!({"response_b64": b64(&signed)}))),
        "registry_endpoints" => {
            let response = json!({"observations": [{"deviceId": "device-1", "endpointGeneration": "3"}], "meshRevision": "12"});
            Some((200, json!({"response_b64": b64(response.to_string())})))
        }
        "registry_join" => Some((409, json!({"error": "revision_conflict"}))),
        _ => None,
    });
    let harness = start(Some(handler)).await;
    let (mux, _inbound) = testing::dial(&harness.addr, "localhost", harness.certificate.as_bytes())
        .await
        .unwrap();
    let identity = testing::identity("x-agentvmm-registration-id", REGISTRATION, CREDENTIAL);
    let service = "/agentvmm.trust.v1.PersonalMeshRegistryService/";

    let request = trust::GetSnapshotRequest {
        mesh_id: "mesh-1".into(),
        minimum_revision: 7,
    };
    let response: trust::GetSnapshotResponse = testing::unary(
        &mux,
        &format!("{service}GetSnapshot"),
        identity.clone(),
        &request,
    )
    .await
    .unwrap();
    assert_eq!(response, snapshot);
    let sent = decode(&harness.salix.call("registry_snapshot", 0).await["request_json_b64"]);
    assert_eq!(sent, json!({"meshId": "mesh-1", "minimumRevision": "7"}));

    let request = trust::ListEndpointsRequest {
        mesh_id: "mesh-1".into(),
        expected_revision: 12,
    };
    let response: trust::ListEndpointsResponse = testing::unary(
        &mux,
        &format!("{service}ListEndpoints"),
        identity.clone(),
        &request,
    )
    .await
    .unwrap();
    assert_eq!(response.mesh_revision, 12);
    assert_eq!(
        (
            response.observations[0].device_id.as_str(),
            response.observations[0].endpoint_generation
        ),
        ("device-1", 3)
    );

    // Salix's refusal reaches the Host with its reason.
    let conflict = testing::unary::<_, trust::CommitJoinResponse>(
        &mux,
        &format!("{service}CommitJoin"),
        identity,
        &trust::CommitJoinRequest::default(),
    )
    .await
    .unwrap_err();
    assert_eq!(
        (conflict.code, conflict.message.as_str()),
        (Code::Unknown, "control status 409: revision_conflict")
    );

    // A rejected credential never reaches the registry.
    let rejected = testing::identity("x-agentvmm-registration-id", "rejected", CREDENTIAL);
    let refused = testing::unary::<_, trust::GetSnapshotResponse>(
        &mux,
        &format!("{service}GetSnapshot"),
        rejected,
        &request_snapshot(),
    )
    .await
    .unwrap_err();
    assert_eq!(refused.code, Code::Unauthenticated);
    assert_eq!(harness.salix.calls("registry_snapshot").len(), 1);
}

fn request_snapshot() -> trust::GetSnapshotRequest {
    trust::GetSnapshotRequest {
        mesh_id: "mesh-1".into(),
        minimum_revision: 0,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_iroh_tunnel_carries_one_stream_to_the_dialed_endpoint() {
    use iroh::{Endpoint, endpoint::presets};

    let peer = Endpoint::builder(presets::Minimal)
        .alpns(vec![b"agent-vmm/service-tunnel/1".to_vec()])
        .bind_addr("127.0.0.1:0")
        .unwrap()
        .bind()
        .await
        .unwrap();
    let address = serde_json::to_value(peer.addr()).unwrap();
    let accepting = peer.clone();
    tokio::spawn(async move {
        while let Some(incoming) = accepting.accept().await {
            tokio::spawn(async move {
                let connection = incoming.await.unwrap();
                let (mut send, mut receive) = connection.accept_bi().await.unwrap();
                // As a Host does: read the whole request, then answer it and end.
                let request = receive.read_to_end(1 << 16).await.unwrap();
                send.write_all(&request.to_ascii_uppercase()).await.unwrap();
                let _ = send.finish();
                connection.closed().await;
            });
        }
    });

    let harness = start(None).await;
    let mut stream = harness
        .local(json!({"token": harness.token, "op": "iroh_tunnel", "endpoint_addr": address}))
        .await;
    let answer = read_packet(&mut stream).await.unwrap().unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&answer).unwrap(),
        json!({"type": "ready"})
    );
    // The caller ends its request with a write half-close, as a `vmm-rpc`
    // client does, and still reads the whole answer the peer sends afterwards.
    stream.write_all(b"service bytes").await.unwrap();
    stream.shutdown().await.unwrap();
    let mut reply = Vec::new();
    stream.read_to_end(&mut reply).await.unwrap();
    assert_eq!(reply, b"SERVICE BYTES");
    drop(stream);

    // An address that names no endpoint is refused before any dial; the token is required.
    let (status, error) = harness
        .request(json!({"token": harness.token, "op": "iroh_tunnel", "endpoint_addr": {"id": 7}}))
        .await;
    assert_eq!(
        (status, error),
        (400, json!({"error": "invalid endpoint address"}))
    );
    assert_eq!(
        harness
            .request(json!({"token": "wrong", "op": "iroh_tunnel", "endpoint_addr": address}))
            .await
            .0,
        401
    );
    let counted = harness
        .salix
        .wait(|salix| {
            let events = salix.events.lock().unwrap();
            let count = |name: &str| {
                events
                    .iter()
                    .filter(|event| event["event"] == "count" && event["name"] == name)
                    .count()
            };
            (count("iroh_connect") == 2).then(|| count("iroh_connect_failure"))
        })
        .await;
    assert_eq!(counted, 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_worker_ends_when_salix_closes_the_control_channel() {
    let directory = tempfile::tempdir().unwrap();
    let (certificate, key) = testing::generate_certificate();
    std::fs::write(directory.path().join("tls.crt"), &certificate).unwrap();
    std::fs::write(directory.path().join("tls.key"), key).unwrap();
    let socket = directory.path().join("worker.sock");
    let config: Config = serde_json::from_value(json!({
        "instance_id": "comma-0", "remote_listen": "127.0.0.1:0",
        "tls_cert_file": directory.path().join("tls.crt"),
        "tls_key_file": directory.path().join("tls.key"),
        "socket": socket, "token": "t".repeat(43),
    }))
    .unwrap();
    let (worker_end, salix_end) = tokio::io::duplex(1 << 16);
    let (worker_read, worker_write) = tokio::io::split(worker_end);
    let worker = tokio::spawn(salix_vmm_worker::run(
        config,
        worker_read,
        worker_write,
        CancellationToken::new(),
    ));
    let (mut read, write) = tokio::io::split(salix_end);
    let ready: Value =
        serde_json::from_slice(&read_packet(&mut read).await.unwrap().unwrap()).unwrap();
    let addr = ready["remote_addr"].as_str().unwrap().to_owned();
    assert!(socket.exists());

    // Salix leaving is the worker's end: it stops listening and removes its socket.
    drop((read, write));
    worker.await.unwrap().unwrap();
    assert!(!socket.exists());
    assert!(
        testing::dial(&addr, "localhost", certificate.as_bytes())
            .await
            .is_err()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn workspace_write_accepts_omitted_or_explicit_prefix_digest() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;

    let (status, written) = harness
        .operation(
            "allocation-1",
            "compute.workspace.write",
            json!({
                "path": "omitted.txt",
                "content_base64": b64("hello"),
                "request_id": "w-omitted",
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(written["entry"]["path"], "omitted.txt");
    let (_, header) = runtime_call(&mut host, "WriteWorkspace").await;
    assert!(
        header.get("expected_prefix_sha256").is_none()
            || header["expected_prefix_sha256"] == json!("")
    );

    let prefix_digest = b64([0xabu8; 32]);
    let (status, written) = harness
        .operation(
            "allocation-1",
            "compute.workspace.write",
            json!({
                "path": "explicit.txt",
                "offset": 12,
                "content_base64": b64("world"),
                "expected_prefix_sha256": prefix_digest,
                "request_id": "w-explicit",
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(written["entry"]["path"], "explicit.txt");
    let (_, header) = runtime_call(&mut host, "WriteWorkspace").await;
    assert_eq!(header["offset"], "12");
    assert_eq!(header["expected_prefix_sha256"], prefix_digest);
}

#[tokio::test(flavor = "multi_thread")]
async fn process_tail_wait_ms_wakes_on_output_timeout_and_exit() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;

    let (status, _) = harness
        .operation(
            "allocation-1",
            "process.start",
            json!({"command": ["serve"], "request_id": "tail-wait-1"}),
        )
        .await;
    assert_eq!(status, 200);
    let _ = runtime_call(&mut host, "Exec").await;

    // 1. Initial output arrives and wakes the wait.
    let (status, initial) = harness
        .operation(
            "allocation-1",
            "process.tail",
            json!({"process_id": "process-request-tail-wait-1", "wait_ms": 30_000}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(initial["stdout_base64"], b64("ready\n"));

    // 2. No new output: wait_ms elapses and returns running snapshot unchanged.
    let (status, timed_out) = harness
        .operation(
            "allocation-1",
            "process.tail",
            json!({"process_id": "process-request-tail-wait-1", "wait_ms": 1}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(timed_out["state"], "running");
    assert_eq!(timed_out["stdout_base64"], b64("ready\n"));

    let tail_request = || {
        json!({
            "token": harness.token,
            "op": "session_call",
            "operation": "process.tail",
            "args": {"process_id": "process-request-tail-wait-1", "wait_ms": 30_000},
            "session": harness.session("allocation-1", 3, EPOCH),
        })
    };

    // 3. New output arriving while process.tail is waiting wakes it immediately.
    let mut output_wait = harness.local(tail_request()).await;
    let (write_status, _) = harness
        .operation(
            "allocation-1",
            "process.write",
            json!({"process_id": "process-request-tail-wait-1", "data_base64": b64("ping")}),
        )
        .await;
    assert_eq!(write_status, 200);
    let reply: Value =
        serde_json::from_slice(&read_packet(&mut output_wait).await.unwrap().unwrap()).unwrap();
    assert_eq!(reply["status"], 200);
    assert_eq!(reply["body"]["stdout_base64"], b64("ready\nping"));

    // 4. Process exit while process.tail is waiting wakes it with exited state.
    let mut exit_wait = harness.local(tail_request()).await;
    let (stop_status, _) = harness
        .operation(
            "allocation-1",
            "process.stop",
            json!({"process_id": "process-request-tail-wait-1", "signal": "int"}),
        )
        .await;
    assert_eq!(stop_status, 200);
    let reply: Value =
        serde_json::from_slice(&read_packet(&mut exit_wait).await.unwrap().unwrap()).unwrap();
    assert_eq!(reply["status"], 200);
    assert_eq!(reply["body"]["state"], "exited");
    assert_eq!(reply["body"]["exit_code"], 130);
}

#[tokio::test(flavor = "multi_thread")]
async fn compute_exec_forwards_timeout_and_surfaces_timeout_and_oom_diagnostics() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;

    // Custom timeout_ms forwarded (and clamped to 300_000), timed_out + memory_peak_bytes surfaced.
    let (status, result) = harness
        .operation(
            "allocation-1",
            "compute.exec",
            json!({
                "command": ["timeout"],
                "request_id": "exec-timeout-1",
                "timeout_ms": 500_000,
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        result,
        json!({
            "stdout_base64": b64("partial"),
            "stderr_base64": b64(""),
            "exit_code": 124,
            "timed_out": true,
            "oom_killed": false,
            "memory_peak_bytes": 4 * 1024 * 1024,
        })
    );
    let (_, start) = runtime_call(&mut host, "Exec").await;
    assert_eq!(start["timeout_ms"], "300000");

    // OOM killed exec surfaces oom_killed + memory_peak_bytes; small timeout_ms clamped to 1_000.
    let (status, result) = harness
        .operation(
            "allocation-1",
            "compute.exec",
            json!({
                "command": ["oom"],
                "request_id": "exec-oom-1",
                "timeout_ms": 50,
            }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        result,
        json!({
            "stdout_base64": b64(""),
            "stderr_base64": b64(""),
            "exit_code": 137,
            "timed_out": false,
            "oom_killed": true,
            "memory_peak_bytes": 512 * 1024 * 1024,
        })
    );
    let (_, start) = runtime_call(&mut host, "Exec").await;
    assert_eq!(start["timeout_ms"], "1000");
}

#[tokio::test(flavor = "multi_thread")]
async fn process_tail_and_list_surface_oom_killed_and_memory_peak() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;

    let (status, started) = harness
        .operation(
            "allocation-1",
            "process.start",
            json!({"command": ["oom"], "request_id": "proc-oom-1", "timeout_ms": 12_000}),
        )
        .await;
    assert_eq!(status, 200);
    let process_id = started["process_id"].as_str().unwrap().to_owned();
    let (_, start) = runtime_call(&mut host, "Exec").await;
    assert!(start.get("timeout_ms").is_none() || start["timeout_ms"] == json!("0"));

    let (status, tailed) = harness
        .operation(
            "allocation-1",
            "process.tail",
            json!({"process_id": process_id, "wait_ms": 5_000}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(tailed["state"], "exited");
    assert_eq!(tailed["exit_code"], 137);
    assert_eq!(tailed["oom_killed"], true);
    assert_eq!(tailed["memory_peak_bytes"], 512 * 1024 * 1024);

    let (status, listed) = harness
        .operation("allocation-1", "process.list", json!({}))
        .await;
    assert_eq!(status, 200);
    assert_eq!(
        listed,
        json!({
            "processes": [{
                "process_id": process_id,
                "state": "exited",
                "exit_code": 137,
                "oom_killed": true,
                "memory_peak_bytes": 512 * 1024 * 1024,
            }]
        })
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn workspace_list_supports_cursor_pagination_and_omits_empty_sha256() {
    let harness = start(None).await;
    let mut host = harness.host(EPOCH).await;
    ready(&mut host).await;
    harness.open_session("allocation-1", 3).await;

    // Default limit is 100, clamped at 500.
    let (status, all) = harness
        .operation(
            "allocation-1",
            "compute.workspace.list",
            json!({"path": "."}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(all["entries"].as_array().unwrap().len(), 5);
    assert_eq!(all["has_more"], false);
    assert_eq!(all["next_cursor"], Value::Null);
    for entry in all["entries"].as_array().unwrap() {
        assert!(entry.get("sha256").is_none());
    }
    let (_, req) = runtime_call(&mut host, "ListWorkspace").await;
    assert_eq!(req["limit"], 100);

    // Explicit limit=2 paginates across 3 pages via cursor.
    let (status, page1) = harness
        .operation(
            "allocation-1",
            "compute.workspace.list",
            json!({"path": ".", "limit": 2}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(page1["entries"].as_array().unwrap().len(), 2);
    assert_eq!(page1["entries"][0]["path"], "file-0.txt");
    assert_eq!(page1["entries"][1]["path"], "file-1.txt");
    assert_eq!(page1["has_more"], true);
    assert_eq!(page1["next_cursor"], "2");
    let (_, req1) = runtime_call(&mut host, "ListWorkspace").await;
    assert_eq!(req1["limit"], 2);

    let (status, page2) = harness
        .operation(
            "allocation-1",
            "compute.workspace.list",
            json!({"path": ".", "limit": 2, "cursor": page1["next_cursor"]}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(page2["entries"].as_array().unwrap().len(), 2);
    assert_eq!(page2["entries"][0]["path"], "file-2.txt");
    assert_eq!(page2["entries"][1]["path"], "file-3.txt");
    assert_eq!(page2["has_more"], true);
    assert_eq!(page2["next_cursor"], "4");
    let (_, req2) = runtime_call(&mut host, "ListWorkspace").await;
    assert_eq!(req2["cursor"], "2");

    let (status, page3) = harness
        .operation(
            "allocation-1",
            "compute.workspace.list",
            json!({"path": ".", "limit": 999, "cursor": page2["next_cursor"]}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(page3["entries"].as_array().unwrap().len(), 1);
    assert_eq!(page3["entries"][0]["path"], "file-4.txt");
    assert_eq!(page3["has_more"], false);
    assert_eq!(page3["next_cursor"], Value::Null);
    let (_, req3) = runtime_call(&mut host, "ListWorkspace").await;
    assert_eq!(req3["limit"], 500);
    assert_eq!(req3["cursor"], "4");
}
