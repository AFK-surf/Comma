//! A scripted Agent VMM Host for tests: the Host side of `agent-vmm/rpc/1`,
//! with a small in-memory runtime. Never built into the release worker.

use crate::{
    connect::ERROR_DOMAIN,
    mux::{self, MuxHandle, Stream},
    pb::{
        self, host,
        remote::{
            self, CommandAck, CommandAckDisposition, CommandEvidence, CommandOutcome,
            CommandResult, ConnectRequest, ConnectResponse, ControllerCommand, ErrorReason,
            HostHello, command_result, connect_request, connect_response,
            controller_command::Command,
        },
    },
    rpc::{self, ClientCall, ServerCall},
    status::{Code, Status},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use prost::{Message, Name};
use serde_json::Value;
use std::{
    collections::HashMap,
    io,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::{net::TcpStream, sync::mpsc};
use tokio_rustls::TlsConnector;

pub const CONNECT: &str = "/agentvmm.remote.v1.RemoteControllerService/Connect";
const RUNTIME: &str = "/agentvmm.host.v1.AgentRuntimeService/";

/// A self-signed certificate and its key for `localhost` and `127.0.0.1`, as PEM.
pub fn generate_certificate() -> (String, String) {
    let names = vec!["localhost".to_owned(), "127.0.0.1".to_owned()];
    let certificate = rcgen::generate_simple_self_signed(names).expect("a test certificate");
    (
        certificate.cert.pem(),
        certificate.signing_key.serialize_pem(),
    )
}

/// Connects as a Host would: TLS 1.3, the `agent-vmm/rpc/1` ALPN, then yamux.
pub async fn dial(
    addr: &str,
    server_name: &str,
    trust_pem: &[u8],
) -> io::Result<(MuxHandle, mpsc::Receiver<Stream>)> {
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_pemfile::certs(&mut &*trust_pem) {
        roots.add(certificate?).map_err(io::Error::other)?;
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(io::Error::other)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![rpc::ALPN.to_vec()];
    let name = rustls::pki_types::ServerName::try_from(server_name.to_owned())
        .map_err(io::Error::other)?;
    let socket = TcpStream::connect(addr).await?;
    socket.set_nodelay(true)?;
    let stream = TlsConnector::from(Arc::new(tls))
        .connect(name, socket)
        .await?;
    Ok(mux::spawn(stream, yamux::Mode::Client, 1024))
}

pub fn identity(
    registration_header: &str,
    registration_id: &str,
    credential: &[u8],
) -> Vec<(String, String)> {
    vec![
        (
            "authorization".into(),
            format!("Bearer {}", STANDARD.encode(credential)),
        ),
        (registration_header.into(), registration_id.into()),
    ]
}

/// One unary call as a Host makes it.
pub async fn unary<Request: Message, Response: Message + Default>(
    mux: &MuxHandle,
    method: &str,
    metadata: Vec<(String, String)>,
    request: &Request,
) -> Result<Response, Status> {
    let (read, write) = mux.open().await?;
    let ClientCall { mut tx, mut rx } = rpc::open(read, write, method, metadata, None).await?;
    tx.send(request).await?;
    tx.close().await?;
    let response = rx.message::<Response>().await?;
    match rx.message::<Response>().await? {
        None => response.ok_or_else(|| Status::new(Code::Internal, "response message required")),
        Some(_) => Err(Status::new(Code::Internal, "unexpected response message")),
    }
}

#[derive(Debug, Clone)]
pub struct HostConfig {
    pub registration_id: String,
    pub credential: Vec<u8>,
    pub connection_epoch: u64,
    pub protocol_version: String,
    pub registration_header: String,
    /// The allocations the Host already holds, and the watermark of that inventory.
    pub inventory: Vec<remote::Allocation>,
    pub inventory_watermark: u64,
}

impl HostConfig {
    pub fn new(registration_id: &str, credential: &[u8], connection_epoch: u64) -> Self {
        Self {
            registration_id: registration_id.into(),
            credential: credential.to_vec(),
            connection_epoch,
            protocol_version: "5".into(),
            registration_header: "x-agentvmm-registration-id".into(),
            inventory: Vec::new(),
            inventory_watermark: 1,
        }
    }
}

#[derive(Debug, Clone)]
pub enum Event {
    Ready(remote::ControllerReady),
    Command(ControllerCommand),
    /// The Connect call's terminal status.
    Ended(Status),
    /// A runtime call the worker made: its method, metadata, and first request as proto-name JSON.
    Runtime {
        method: String,
        metadata: Vec<(String, String)>,
        request: Value,
    },
}

struct State {
    config: HostConfig,
    events: mpsc::UnboundedSender<Event>,
    /// Issued nonce -> allocation.
    sessions: Mutex<HashMap<String, String>>,
    issued: Mutex<u64>,
    /// The request streams of refused calls: held open and never read again.
    refused: Mutex<Vec<rpc::ServerReceiver>>,
}

pub struct Host {
    pub events: mpsc::UnboundedReceiver<Event>,
    pub mux: MuxHandle,
    outbound: mpsc::UnboundedSender<ConnectRequest>,
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

fn host_error(code: Code, reason: &str, metadata: &[(&str, &str)]) -> Status {
    let metadata = metadata
        .iter()
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect();
    // Host text is private: the worker must never forward it.
    Status::with_error_info(
        code,
        "host-private /var/lib/agent-vmm detail",
        ERROR_DOMAIN,
        reason,
        metadata,
    )
}

impl Host {
    /// Connects, sends the hello and serves commands and runtime calls until the connection ends.
    pub async fn start(addr: &str, trust_pem: &[u8], config: HostConfig) -> io::Result<Self> {
        let (mux, inbound) = dial(addr, "localhost", trust_pem).await?;
        let (events_tx, events) = mpsc::unbounded_channel();
        let (outbound, manual) = mpsc::unbounded_channel();
        let state = Arc::new(State {
            config,
            events: events_tx,
            sessions: Mutex::default(),
            issued: Mutex::new(0),
            refused: Mutex::default(),
        });
        tokio::spawn(serve_runtime(state.clone(), inbound));
        tokio::spawn(control(state, mux.clone(), manual));
        Ok(Self {
            events,
            mux,
            outbound,
        })
    }

    /// Sends one frame on the control stream as the Host.
    pub fn send(&self, payload: connect_request::Payload) {
        let _ = self.outbound.send(ConnectRequest {
            payload: Some(payload),
        });
    }

    pub async fn next(&mut self) -> Event {
        self.events.recv().await.expect("the host is running")
    }

    /// Skips events until one matches.
    pub async fn until<T>(&mut self, mut matches: impl FnMut(&Event) -> Option<T>) -> T {
        loop {
            if let Some(found) = matches(&self.next().await) {
                return found;
            }
        }
    }

    pub fn close(&self) {
        self.mux.close();
    }
}

async fn control(
    state: Arc<State>,
    mux: MuxHandle,
    mut manual: mpsc::UnboundedReceiver<ConnectRequest>,
) {
    let config = &state.config;
    let ended = |status: Status| {
        let _ = state.events.send(Event::Ended(status));
    };
    let opened = async {
        let (read, write) = mux.open().await?;
        let metadata = identity(
            &config.registration_header,
            &config.registration_id,
            &config.credential,
        );
        rpc::open(read, write, CONNECT, metadata, None).await
    };
    let ClientCall { mut tx, mut rx } = match opened.await {
        Ok(call) => call,
        Err(status) => return ended(status),
    };
    let hello = HostHello {
        protocol_version: config.protocol_version.clone(),
        connector_release: "test".into(),
        registration_id: config.registration_id.clone(),
        connection_instance: "0123456789abcdef0123456789abcdef".into(),
        pool_revision: 1,
        capacity: Some(capacity()),
        inventory: config.inventory.clone(),
        connection_epoch: config.connection_epoch,
        inventory_watermark: config.inventory_watermark,
        supported_features: vec!["remote-observation-v1".into()],
        observation: Some(observation(1)),
        ..Default::default()
    };
    let hello = ConnectRequest {
        payload: Some(connect_request::Payload::Hello(hello)),
    };
    if let Err(status) = tx.send(&hello).await {
        return ended(status);
    }
    let mut watermark = config.inventory_watermark;
    loop {
        tokio::select! {
            frame = rx.message::<ConnectResponse>() => {
                let payload = match frame {
                    Ok(Some(frame)) => frame.payload,
                    Ok(None) => return ended(Status::ok()),
                    Err(status) => return ended(status),
                };
                match payload {
                    Some(connect_response::Payload::ControllerReady(ready)) => {
                        let _ = state.events.send(Event::Ready(ready));
                    }
                    Some(connect_response::Payload::Command(command)) => {
                        let _ = state.events.send(Event::Command(command.clone()));
                        for reply in answer(&state, &command, &mut watermark) {
                            if tx.send(&ConnectRequest { payload: Some(reply) }).await.is_err() {
                                break;
                            }
                        }
                    }
                    None => {}
                }
            }
            frame = manual.recv() => {
                let Some(frame) = frame else { return };
                let _ = tx.send(&frame).await;
            }
        }
    }
}

fn capacity() -> remote::Capacity {
    remote::Capacity {
        per_environment_limits: Some(remote::ResourceLimits {
            pids: Some(512),
            disk_bytes: Some(10 << 30),
        }),
        max_egress_mode: remote::EgressMode::PublicInternet as i32,
    }
}

pub fn observation(sequence: u64) -> remote::RemoteObservationSnapshot {
    let now = unix_millis();
    remote::RemoteObservationSnapshot {
        sequence,
        observed_unix_millis: now,
        capacity: Some(capacity()),
        health: Some(remote::RemoteObservationHealth {
            status: "healthy".into(),
            ..Default::default()
        }),
        inventory_watermark: 1,
        inventory_observed_unix_millis: now,
        ..Default::default()
    }
}

/// The frames a Host sends for one command: its admission, its start, its result.
fn answer(
    state: &State,
    command: &ControllerCommand,
    watermark: &mut u64,
) -> Vec<connect_request::Payload> {
    let ack = |disposition: CommandAckDisposition, reason: ErrorReason| {
        connect_request::Payload::Ack(CommandAck {
            command_id: command.command_id.clone(),
            sequence: command.sequence,
            connection_epoch: command.connection_epoch,
            disposition: disposition as i32,
            reason: reason as i32,
            message: String::new(),
        })
    };
    let result = match &command.command {
        Some(Command::EnsureAllocation(ensure)) => {
            // An allocation named `full…` meets a Host without capacity, before any mutation.
            if ensure.allocation_id.starts_with("full") {
                return vec![ack(
                    CommandAckDisposition::Rejected,
                    ErrorReason::CapacityExhausted,
                )];
            }
            *watermark += 1;
            Some(command_result::Result::Allocation(remote::Allocation {
                allocation_id: ensure.allocation_id.clone(),
                display_label: ensure.display_label.clone(),
                limits: ensure.limits,
                egress_mode: ensure.egress_mode,
                revision: ensure.policy_revision.max(1),
                state: remote::AllocationState::Ready as i32,
                generation: ensure.generation,
            }))
        }
        Some(Command::OpenSession(open)) => {
            let nonce = {
                let mut issued = state.issued.lock().expect("issued");
                *issued += 1;
                format!(
                    "{:032x}",
                    (state.config.connection_epoch as u128) << 64 | *issued as u128
                )
            };
            let mut sessions = state.sessions.lock().expect("sessions");
            // A replacement revokes the allocation's previous capability.
            sessions.retain(|_, allocation| *allocation != open.allocation_id);
            sessions.insert(nonce.clone(), open.allocation_id.clone());
            Some(command_result::Result::SessionReady(remote::SessionReady {
                allocation_id: open.allocation_id.clone(),
                allocation_generation: open.allocation_generation,
                tunnel_nonce: nonce,
                expires_unix_millis: unix_millis() + 8 * 60 * 60 * 1000,
            }))
        }
        Some(Command::ReleaseAllocation(release)) => {
            *watermark += 1;
            Some(command_result::Result::Allocation(remote::Allocation {
                allocation_id: release.allocation_id.clone(),
                revision: release.expected_revision + 1,
                state: remote::AllocationState::Retained as i32,
                generation: release.expected_generation,
                ..Default::default()
            }))
        }
        _ => {
            return vec![ack(
                CommandAckDisposition::Rejected,
                ErrorReason::InvalidArgument,
            )];
        }
    };
    let evidence = connect_request::Payload::Evidence(CommandEvidence {
        command_id: command.command_id.clone(),
        sequence: command.sequence,
        connection_epoch: command.connection_epoch,
        stage: remote::ExecutionStage::Started as i32,
        observed_unix_millis: unix_millis(),
    });
    let result = connect_request::Payload::Result(CommandResult {
        command_id: command.command_id.clone(),
        outcome: CommandOutcome::Succeeded as i32,
        result,
        sequence: command.sequence,
        connection_epoch: command.connection_epoch,
        inventory_watermark: *watermark,
        ..Default::default()
    });
    vec![
        ack(CommandAckDisposition::Admitted, ErrorReason::Unspecified),
        evidence,
        result,
    ]
}

// ---- the runtime the worker calls ------------------------------------------------

async fn serve_runtime(state: Arc<State>, mut inbound: mpsc::Receiver<Stream>) {
    while let Some((read, write)) = inbound.recv().await {
        let state = state.clone();
        tokio::spawn(async move {
            let Ok(mut call) = rpc::accept(read, write).await else {
                return;
            };
            let status = match runtime(&state, &mut call).await {
                Ok(()) => Status::ok(),
                Err(status) => status,
            };
            let _ = call.tx.finish(&status).await;
            if !status.is_ok() {
                // A Host that refuses a call stops reading it: the worker gets
                // no more stream window for what it has left to send.
                state.refused.lock().expect("refused").push(call.rx);
            }
        });
    }
}

fn authorized(state: &State, call: &ServerCall) -> bool {
    let bearer: Vec<&str> = call.header.values("authorization").collect();
    let allocation: Vec<&str> = call.header.values("x-agentvmm-allocation-id").collect();
    let generation: Vec<&str> = call
        .header
        .values("x-agentvmm-allocation-generation")
        .collect();
    let (&[bearer], &[allocation], &[generation]) = (&bearer[..], &allocation[..], &generation[..])
    else {
        return false;
    };
    let sessions = state.sessions.lock().expect("sessions");
    generation.parse::<u64>().is_ok()
        && bearer
            .strip_prefix("Bearer ")
            .and_then(|nonce| sessions.get(nonce))
            .is_some_and(|issued| issued == allocation)
}

async fn request<M: Message + Default>(call: &mut ServerCall) -> Result<M, Status> {
    let bytes = call
        .rx
        .message()
        .await?
        .ok_or_else(|| Status::new(Code::InvalidArgument, "request message required"))?;
    M::decode(bytes.as_slice()).map_err(|_| Status::new(Code::InvalidArgument, "invalid request"))
}

async fn respond<M: Message>(call: &mut ServerCall, message: &M) -> Result<(), Status> {
    call.tx
        .message(&message.encode_to_vec())
        .await
        .map_err(|_| Status::new(Code::Unavailable, "worker left"))
}

fn record<M: Message + Name>(state: &State, call: &ServerCall, request: &M) {
    let _ = state.events.send(Event::Runtime {
        method: call.header.method.trim_start_matches(RUNTIME).to_owned(),
        metadata: call.header.metadata.clone(),
        request: pb::to_proto_name_json(request).unwrap_or(Value::Null),
    });
}

fn container() -> host::Container {
    host::Container {
        id: "workload".into(),
        image: "comma.local/runtime/shell".into(),
        state: host::ContainerState::Running as i32,
        instance_id: "instance-1".into(),
        generation_id: "generation-1".into(),
        ..Default::default()
    }
}

async fn runtime(state: &State, call: &mut ServerCall) -> Result<(), Status> {
    if !authorized(state, call) {
        return Err(Status::new(
            Code::Unauthenticated,
            "session capability rejected",
        ));
    }
    let method = call.header.method.trim_start_matches(RUNTIME).to_owned();
    match method.as_str() {
        "GetEnvironment" => {
            let _: host::GetEnvironmentRequest = request(call).await?;
            let environment = host::AgentEnvironment {
                id: "environment".into(),
                containers: vec![container()],
                ..Default::default()
            };
            respond(
                call,
                &host::GetEnvironmentResponse {
                    environment: Some(environment),
                },
            )
            .await
        }
        "Exec" => exec(state, call).await,
        "ImportImage" => {
            let message: host::ImportImageRequest = request(call).await?;
            let Some(host::import_image_request::Payload::Header(header)) = message.payload else {
                return Err(Status::new(Code::InvalidArgument, "import header required"));
            };
            record(state, call, &header);
            let mut image = host::Image {
                reference: header.image_reference.clone(),
                digest: header.manifest_digest.clone(),
                logical_bytes: header.archive_size,
                platforms: vec![header.platform.clone()],
                generation_id: "generation-1".into(),
                ..Default::default()
            };
            match header.request_id.split('-').next().unwrap_or_default() {
                "full" => {
                    return Err(host_error(
                        Code::ResourceExhausted,
                        "RESOURCE_CAPACITY_EXHAUSTED",
                        &[
                            ("resource_dimension", "storage_headroom"),
                            ("stage", "import_admission"),
                            ("available_bytes", "1024"),
                            ("required_bytes", "4096"),
                        ],
                    ));
                }
                "busy" => {
                    return Err(host_error(
                        Code::ResourceExhausted,
                        "RESOURCE_CAPACITY_EXHAUSTED",
                        &[
                            ("resource_dimension", "import_slot"),
                            ("stage", "import_slot"),
                        ],
                    ));
                }
                "mismatch" => image.digest = format!("sha256:{}", "0".repeat(64)),
                _ => {}
            }
            respond(call, &host::ImportImageResponse { image: Some(image) }).await
        }
        "ListImages" => {
            let message: host::ListImagesRequest = request(call).await?;
            record(state, call, &message);
            respond(call, &host::ListImagesResponse::default()).await
        }
        "StartContainer" => {
            let message: host::StartContainerRequest = request(call).await?;
            record(state, call, &message);
            if message.container_id == "stale" {
                return Err(host_error(Code::Aborted, "STALE_CONTAINER_INSTANCE", &[]));
            }
            respond(
                call,
                &host::StartContainerResponse {
                    container: Some(container()),
                },
            )
            .await
        }
        "CreateContainer" => {
            let message: host::CreateContainerRequest = request(call).await?;
            record(state, call, &message);
            let created = host::Container {
                id: message.container_id.clone(),
                image: message.image.clone(),
                state: host::ContainerState::Created as i32,
                ..Default::default()
            };
            respond(
                call,
                &host::CreateContainerResponse {
                    container: Some(created),
                },
            )
            .await
        }
        "AcquireExecution" => {
            let message: host::AcquireExecutionRequest = request(call).await?;
            record(state, call, &message);
            if message.execution_id == "busy" {
                return Err(host_error(
                    Code::ResourceExhausted,
                    "WORKLOAD_EXECUTION_BUSY",
                    &[],
                ));
            }
            let response = host::AcquireExecutionResponse {
                execution_id: message.execution_id,
                container_instance_id: message.expected_instance_id,
                acquired: true,
            };
            respond(call, &response).await
        }
        "ReleaseExecution" => {
            let message: host::ReleaseExecutionRequest = request(call).await?;
            record(state, call, &message);
            respond(call, &host::ReleaseExecutionResponse {}).await
        }
        "StatWorkspace" => {
            let message: host::StatWorkspaceRequest = request(call).await?;
            let entry = host::WorkspaceEntry {
                path: message.path,
                size: 11,
                ..Default::default()
            };
            respond(call, &host::StatWorkspaceResponse { entry: Some(entry) }).await
        }
        "ListWorkspace" => {
            let message: host::ListWorkspaceRequest = request(call).await?;
            record(state, call, &message);
            let total: Vec<host::WorkspaceEntry> = (0..5)
                .map(|index| host::WorkspaceEntry {
                    path: format!("file-{index}.txt"),
                    kind: host::WorkspaceEntryKind::File as i32,
                    size: (index as u64 + 1) * 10,
                    mode: 0o644,
                    modified_unix_nanos: 1_700_000_000_000_000_000 + index as i64,
                    sha256: Vec::new(),
                })
                .collect();
            let start = message.cursor.parse::<usize>().unwrap_or(0);
            let limit = message.limit as usize;
            let end = (start + limit).min(total.len());
            let entries = if start < total.len() {
                total[start..end].to_vec()
            } else {
                Vec::new()
            };
            let has_more = end < total.len();
            let next_cursor = if has_more {
                end.to_string()
            } else {
                String::new()
            };
            respond(
                call,
                &host::ListWorkspaceResponse {
                    entries,
                    next_cursor,
                    has_more,
                },
            )
            .await
        }
        "ReadWorkspace" => {
            let message: host::ReadWorkspaceRequest = request(call).await?;
            record(state, call, &message);
            for (offset, data, last) in [(0, &b"hello "[..], false), (6, &b"world"[..], true)] {
                let chunk = host::ReadWorkspaceResponse {
                    data: data.to_vec(),
                    offset,
                    sha256: vec![9; 32],
                    r#final: last,
                };
                respond(call, &chunk).await?;
            }
            Ok(())
        }
        "WriteWorkspace" => {
            let mut written = Vec::new();
            let mut header = host::WriteWorkspaceHeader::default();
            let mut finished = false;
            while let Some(bytes) = call.rx.message().await? {
                let message = host::WriteWorkspaceRequest::decode(bytes.as_slice())
                    .map_err(|_| Status::new(Code::InvalidArgument, "invalid request"))?;
                match message.payload {
                    Some(host::write_workspace_request::Payload::Header(value)) => {
                        // The quota is known from the header on.
                        if value.volume_id == "full" {
                            return Err(Status::new(Code::ResourceExhausted, "quota exceeded"));
                        }
                        header = value
                    }
                    Some(host::write_workspace_request::Payload::Data(data)) => {
                        // The real Host accepts at most 64 KiB in one frame.
                        if data.len() > 64 * 1024 {
                            return Err(Status::new(Code::InvalidArgument, "invalid frame"));
                        }
                        written.extend(data)
                    }
                    Some(host::write_workspace_request::Payload::Finish(finish)) => {
                        finished = finish
                    }
                    None => {}
                }
            }
            if !finished {
                return Err(Status::new(Code::InvalidArgument, "write was not finished"));
            }
            record(state, call, &header);
            let entry = host::WorkspaceEntry {
                path: header.path,
                size: written.len() as u64,
                mode: header.mode,
                ..Default::default()
            };
            respond(
                call,
                &host::WriteWorkspaceResponse {
                    entry: Some(entry),
                    sha256: vec![7; 32],
                },
            )
            .await
        }
        "Logs" => {
            let message: host::LogsRequest = request(call).await?;
            record(state, call, &message);
            for index in 0..3 {
                let line = host::LogsResponse {
                    cursor: format!("cursor-{index}"),
                    data: format!("line {index}").into_bytes(),
                    ..Default::default()
                };
                respond(call, &line).await?;
            }
            Ok(())
        }
        "ForwardTCP" => {
            let mut received = Vec::new();
            while let Some(bytes) = call.rx.message().await? {
                let message = host::ForwardTcpRequest::decode(bytes.as_slice())
                    .map_err(|_| Status::new(Code::InvalidArgument, "invalid request"))?;
                match message.event {
                    Some(host::forward_tcp_request::Event::Header(header)) => {
                        record(state, call, &header)
                    }
                    Some(host::forward_tcp_request::Event::Data(data)) => received.extend(data),
                    _ => {}
                }
            }
            let event = |event| host::ForwardTcpResponse { event: Some(event) };
            respond(
                call,
                &event(host::forward_tcp_response::Event::Data(received)),
            )
            .await?;
            respond(
                call,
                &event(host::forward_tcp_response::Event::CloseRead(true)),
            )
            .await
        }
        _ => Err(Status::new(
            Code::Unimplemented,
            "the test host does not serve this method",
        )),
    }
}

/// `echo …` answers its arguments and stdin and exits 0. `serve` runs until
/// signalled, echoing stdin. `flood N` writes N bytes. Anything else exits 127.
async fn exec(state: &State, call: &mut ServerCall) -> Result<(), Status> {
    let first: host::ExecRequest = request(call).await?;
    let Some(host::exec_request::Event::Start(start)) = first.event else {
        return Err(Status::new(Code::InvalidArgument, "exec start required"));
    };
    record(state, call, &start);
    let event = |event| host::ExecResponse {
        event: Some(event),
        ..Default::default()
    };
    let stdout = |bytes: Vec<u8>| event(host::exec_response::Event::Stdout(bytes));
    let exit = |code: u32| event(host::exec_response::Event::ExitCode(code));
    match start.argv.first().map(String::as_str) {
        Some("timeout") => {
            respond(call, &stdout(b"partial".to_vec())).await?;
            respond(
                call,
                &host::ExecResponse {
                    event: Some(host::exec_response::Event::ExitCode(124)),
                    timed_out: true,
                    oom_killed: false,
                    memory_peak_bytes: Some(4 * 1024 * 1024),
                },
            )
            .await
        }
        Some("oom") => {
            respond(
                call,
                &host::ExecResponse {
                    event: Some(host::exec_response::Event::ExitCode(137)),
                    timed_out: false,
                    oom_killed: true,
                    memory_peak_bytes: Some(512 * 1024 * 1024),
                },
            )
            .await
        }
        Some("echo") => {
            let mut output = start.argv[1..].join(" ").into_bytes();
            while let Some(bytes) = call.rx.message().await? {
                let message = host::ExecRequest::decode(bytes.as_slice())
                    .map_err(|_| Status::new(Code::InvalidArgument, "invalid request"))?;
                if let Some(host::exec_request::Event::Stdin(stdin)) = message.event {
                    output.extend(stdin);
                }
            }
            respond(call, &stdout(output)).await?;
            respond(
                call,
                &event(host::exec_response::Event::Stderr(b"warn".to_vec())),
            )
            .await?;
            respond(call, &exit(0)).await
        }
        Some("flood") => {
            let size = start
                .argv
                .get(1)
                .and_then(|size| size.parse().ok())
                .unwrap_or(0usize);
            for chunk in vec![b'x'; size].chunks(1 << 20) {
                respond(call, &stdout(chunk.to_vec())).await?;
            }
            respond(call, &exit(0)).await
        }
        Some("serve") => {
            respond(call, &stdout(b"ready\n".to_vec())).await?;
            while let Some(bytes) = call.rx.message().await? {
                let message = host::ExecRequest::decode(bytes.as_slice())
                    .map_err(|_| Status::new(Code::InvalidArgument, "invalid request"))?;
                match message.event {
                    Some(host::exec_request::Event::Stdin(stdin)) => {
                        respond(call, &stdout(stdin)).await?;
                    }
                    Some(host::exec_request::Event::Signal(signal)) => {
                        let number = match host::ProcessSignal::try_from(signal) {
                            Ok(host::ProcessSignal::Kill) => 9,
                            Ok(host::ProcessSignal::Int) => 2,
                            _ => 15,
                        };
                        return respond(call, &exit(128 + number)).await;
                    }
                    _ => {}
                }
            }
            Ok(())
        }
        _ => respond(call, &exit(127)).await,
    }
}
