//! `RemoteControllerService/Connect`: one Host's control stream. Salix decides
//! everything durable; this loop keeps the order between a Host's hello, the
//! commands Salix has for it and the evidence it sends back.

use crate::{
    control::ControlError,
    gateway::Gateway,
    mux::MuxHandle,
    pb::{
        self,
        remote::{
            self, CommandAckDisposition, CommandOutcome, ConnectRequest, ConnectResponse,
            ControllerCommand, ControllerReady, ErrorReason, HostHello, RemoteObservationRenewal,
            SessionHeader, connect_request, connect_response, controller_command::Command,
        },
    },
    rpc::{RequestHeader, ServerCall, ServerReceiver, ServerSender},
    session::{RuntimeSession, SessionKey},
    status::{Code, Status},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use prost::Message;
use serde_json::{Map, Value, json};
use std::{collections::HashMap, collections::HashSet, sync::Arc, time::Duration};
use tokio::{
    sync::{mpsc, watch},
    time::{Instant, sleep, sleep_until},
};
use tokio_util::sync::CancellationToken;

pub const PROTOCOL_VERSION: u64 = 5;
pub const MIN_PROTOCOL_VERSION: u64 = 5;
pub const OBSERVATION_FEATURE: &str = "remote-observation-v1";
pub const MAX_INVENTORY: usize = 64;
pub const ERROR_DOMAIN: &str = "agent-vmm";
const CLAIM_IDLE: Duration = Duration::from_millis(200);
const CLAIM_RETRY_MAX: Duration = Duration::from_secs(5);
const SETTLE_TIMEOUT: Duration = Duration::from_secs(5);
const COMMIT_TIMEOUT: Duration = Duration::from_secs(10);

/// The registration and opaque credential a Host presents with every call.
pub fn remote_identity(header: &RequestHeader) -> Result<(String, Vec<u8>), Status> {
    let authorization: Vec<&str> = header.values("authorization").collect();
    let registrations: Vec<&str> = header
        .values("x-agentvmm-registration-id")
        .chain(header.values("x-agent-vmm-registration"))
        .collect();
    if authorization.len() != 1 || registrations.len() != 1 {
        return Err(Status::new(
            Code::Unauthenticated,
            "remote credential required",
        ));
    }
    let credential = authorization[0]
        .strip_prefix("Bearer ")
        .and_then(|encoded| STANDARD.decode(encoded).ok())
        .filter(|credential| credential.len() >= 16)
        .ok_or_else(|| Status::new(Code::Unauthenticated, "remote credential invalid"))?;
    Ok((registrations[0].to_owned(), credential))
}

/// Only an authoritative refusal stops the Host for repair. An unavailable
/// control boundary is an ordinary reconnect.
pub fn authentication_control_error(error: &ControlError) -> Status {
    match error.status() {
        Some((401 | 403, _)) => {
            Status::new(Code::Unauthenticated, "registration credential rejected")
        }
        _ => Status::new(
            Code::Unavailable,
            "registration authentication control unavailable",
        ),
    }
}

/// An expired or inactive registration is named, so the Host reports it
/// instead of an anonymous outage. Everything else is retried.
fn observation_control_error(error: &ControlError) -> Status {
    match error.status() {
        Some((403, reason @ ("authorization_expired" | "registration_inactive"))) => {
            Status::new(Code::PermissionDenied, reason)
        }
        _ => Status::new(Code::Unavailable, "connection observation failed"),
    }
}

/// A failed claim supplied no command. The Host connection is kept while only
/// recognized control-plane availability failures are retried.
fn retryable_claim(error: &ControlError) -> bool {
    match error.status() {
        Some((502 | 504, _)) => true,
        Some((503, reason)) => matches!(reason, "" | "control_unavailable" | "pod_draining"),
        Some(_) => false,
        None => true,
    }
}

pub fn validate_hello(hello: &HostHello, registration_id: &str) -> Result<(), Status> {
    let invalid = |message: &str| Err(Status::new(Code::FailedPrecondition, message));
    if hello.registration_id.is_empty() || hello.registration_id != registration_id {
        return invalid("invalid remote registration identity");
    }
    let version = hello.protocol_version.parse::<u64>().ok();
    if !version.is_some_and(|version| (MIN_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&version))
    {
        let side = match version {
            Some(version) if version > PROTOCOL_VERSION => "too_new",
            _ => "too_old",
        };
        let metadata = HashMap::from([
            ("host_protocol".to_owned(), hello.protocol_version.clone()),
            ("min_protocol".to_owned(), MIN_PROTOCOL_VERSION.to_string()),
            ("max_protocol".to_owned(), PROTOCOL_VERSION.to_string()),
            ("host_side".to_owned(), side.to_owned()),
        ]);
        return Err(Status::with_error_info(
            Code::FailedPrecondition,
            "Host protocol is outside the supported range",
            ERROR_DOMAIN,
            "REMOTE_PROTOCOL_UNSUPPORTED",
            metadata,
        ));
    }
    if hello.connection_epoch == 0 {
        return invalid("remote connection contract is incomplete");
    }
    if hello.inventory.len() > MAX_INVENTORY {
        return invalid("remote inventory snapshot exceeds message limit");
    }
    let mut seen = HashSet::new();
    for allocation in &hello.inventory {
        if allocation.allocation_id.is_empty() {
            return invalid("remote inventory contains an empty allocation ID");
        }
        if !seen.insert(allocation.allocation_id.as_str()) {
            return invalid("remote inventory contains a duplicate allocation");
        }
    }
    if hello.inventory_watermark == 0 {
        return invalid("remote inventory watermark is required");
    }
    Ok(())
}

pub async fn serve(gateway: Arc<Gateway>, mux: MuxHandle, call: ServerCall) {
    let ServerCall { header, rx, tx } = call;
    let (status, tx) = connect(&gateway, &mux, &header, rx, tx).await;
    let _ = tx.finish(&status).await;
}

async fn connect(
    gateway: &Arc<Gateway>,
    mux: &MuxHandle,
    header: &RequestHeader,
    mut rx: ServerReceiver,
    tx: ServerSender,
) -> (Status, ServerSender) {
    if gateway.draining() {
        return (Status::new(Code::Unavailable, "gateway is draining"), tx);
    }
    let (registration_id, credential) = match remote_identity(header) {
        Ok(identity) => identity,
        Err(status) => {
            tracing::warn!("registration identity rejected");
            return (status, tx);
        }
    };
    if let Err(error) = gateway.authenticate(&registration_id, &credential).await {
        gateway.count("control_error");
        tracing::warn!(registration_id, %error, "registration authentication failed");
        return (authentication_control_error(&error), tx);
    }
    let hello = match rx.message().await {
        Ok(Some(bytes)) => match ConnectRequest::decode(bytes.as_slice()) {
            Ok(ConnectRequest {
                payload: Some(connect_request::Payload::Hello(hello)),
            }) => hello,
            _ => HostHello::default(),
        },
        _ => {
            return (
                Status::new(Code::FailedPrecondition, "host hello is required"),
                tx,
            );
        }
    };
    if let Err(status) = validate_hello(&hello, &registration_id) {
        tracing::warn!(registration_id, "registration control handshake rejected");
        return (status, tx);
    }
    let epoch = hello.connection_epoch;

    // Observing the hello and becoming the local owner is one ordered handshake.
    // Connection epochs are opaque fences the Host supplies, so the handshake
    // admitted last wins; other registrations proceed independently.
    let handshake = gateway.retain_registration(&registration_id);
    let (status, tx) = async {
        let owner = tokio::select! {
            owner = handshake.lock() => owner,
            _ = mux.closed().cancelled() => {
                return (Status::new(Code::Canceled, "host connection closed"), tx);
            }
        };
        let observed = match pb::to_json(&hello) {
            Ok(hello) => {
                let body = json!({"hello_b64": STANDARD.encode(hello.to_string())});
                gateway
                    .call("observe_hello", body, crate::control::CALL_TIMEOUT)
                    .await
                    .map(drop)
            }
            Err(_) => Err(ControlError::Transport),
        };
        if let Err(error) = observed {
            gateway.count("control_error");
            tracing::warn!(registration_id, connection_epoch = epoch, %error, "registration connection observation failed");
            return (observation_control_error(&error), tx);
        }
        if !gateway.admit_epoch(&registration_id, epoch) {
            return (Status::new(Code::Aborted, "stale connection epoch"), tx);
        }
        drop(owner);
        tracing::info!(registration_id, connection_epoch = epoch, "registration connected");
        gateway.control.event(json!({
            "event": "connected", "registration_id": registration_id,
            "connection_epoch": epoch.to_string(),
        }));

        let mut connection = Connection {
            gateway,
            mux,
            registration_id: &registration_id,
            epoch,
            last_sequence: 0,
            watermark: hello.inventory_watermark,
            terminated: CancellationToken::new(),
        };
        let (status, tx) = connection.run(&hello, rx, tx).await;

        gateway.retire_epoch(&registration_id, epoch);
        gateway.close_connection_sessions(&registration_id, epoch);
        tracing::info!(registration_id, connection_epoch = epoch, "registration disconnected");
        let body = json!({
            "registration_id": registration_id, "connection_epoch": epoch.to_string(),
        });
        let _ = gateway.call("disconnected", body, SETTLE_TIMEOUT).await;
        gateway.control.event(json!({
            "event": "disconnected", "registration_id": registration_id,
            "connection_epoch": epoch.to_string(),
        }));
        (status, tx)
    }
    .await;
    gateway.release_registration(&registration_id);
    (status, tx)
}

#[derive(Default)]
struct Transcript {
    ack: Option<remote::CommandAck>,
    evidence: Vec<remote::CommandEvidence>,
    result: Option<remote::CommandResult>,
}

impl Transcript {
    /// The stored shape of a command's evidence: the ack and the result as
    /// canonical protobuf JSON, the evidence list with its proto field names.
    fn to_json(&self) -> Value {
        let mut transcript = Map::new();
        if let Some(ack) = &self.ack
            && let Ok(ack) = pb::to_json(ack)
        {
            transcript.insert("ack".into(), ack);
        }
        if let Some(result) = &self.result
            && let Ok(result) = pb::to_json(result)
        {
            transcript.insert("result".into(), result);
        }
        if !self.evidence.is_empty() {
            let evidence = self
                .evidence
                .iter()
                .map(|item| {
                    let mut value = Map::new();
                    if !item.command_id.is_empty() {
                        value.insert("command_id".into(), json!(item.command_id));
                    }
                    for (key, number) in [
                        ("sequence", item.sequence as i128),
                        ("connection_epoch", item.connection_epoch as i128),
                        ("stage", item.stage as i128),
                        ("observed_unix_millis", item.observed_unix_millis as i128),
                    ] {
                        if number != 0 {
                            let number = u64::try_from(number)
                                .map(Value::from)
                                .unwrap_or_else(|_| Value::from(number as i64));
                            value.insert(key.into(), number);
                        }
                    }
                    Value::Object(value)
                })
                .collect();
            transcript.insert("evidence".into(), Value::Array(evidence));
        }
        Value::Object(transcript)
    }
}

enum DispatchError {
    /// The command may have run: read the Host's inventory before retrying.
    Unknown,
    /// Nothing was sent.
    Refused(&'static str),
}

struct Connection<'a> {
    gateway: &'a Arc<Gateway>,
    mux: &'a MuxHandle,
    registration_id: &'a str,
    epoch: u64,
    last_sequence: u64,
    watermark: u64,
    /// Cancelled once the Host's stream ended or broke the protocol.
    terminated: CancellationToken,
}

impl Connection<'_> {
    async fn run(
        &mut self,
        hello: &HostHello,
        rx: ServerReceiver,
        mut tx: ServerSender,
    ) -> (Status, ServerSender) {
        // Salix has durably settled this exact hello. Readiness is acknowledged
        // only now, and no command is claimed before this fence.
        let ready = ConnectResponse {
            payload: Some(connect_response::Payload::ControllerReady(
                ControllerReady {
                    registration_id: hello.registration_id.clone(),
                    connection_epoch: self.epoch,
                    acknowledged_inventory_watermark: hello.inventory_watermark,
                    enabled_features: vec![OBSERVATION_FEATURE.into()],
                },
            )),
        };
        if tx.message(&ready.encode_to_vec()).await.is_err() {
            return (
                Status::new(
                    Code::Unavailable,
                    "controller readiness acknowledgement failed",
                ),
                tx,
            );
        }

        let (messages, mut inbox) = mpsc::channel(8);
        let (observations, mut latest) = watch::channel(None::<RemoteObservationRenewal>);
        let receiver = tokio::spawn(receive(
            rx,
            self.epoch,
            messages,
            observations,
            self.terminated.clone(),
        ));
        let settler = {
            let gateway = self.gateway.clone();
            let registration_id = self.registration_id.to_owned();
            tokio::spawn(async move {
                while latest.changed().await.is_ok() {
                    let renewal = latest.borrow_and_update().clone();
                    let Some(renewal) = renewal.and_then(|renewal| pb::to_json(&renewal).ok())
                    else {
                        continue;
                    };
                    let body = json!({
                        "registration_id": registration_id,
                        "renewal_b64": STANDARD.encode(renewal.to_string()),
                    });
                    if gateway
                        .call("settle_observation", body, SETTLE_TIMEOUT)
                        .await
                        .is_err()
                    {
                        gateway.count("control_error");
                        tracing::warn!(
                            registration_id,
                            "registration observation settlement failed"
                        );
                    }
                }
            })
        };

        let status = self.commands(&mut tx, &mut inbox).await;
        self.terminated.cancel();
        receiver.abort();
        settler.abort();
        (status, tx)
    }

    async fn gone(&self) {
        tokio::select! {
            _ = self.terminated.cancelled() => {}
            _ = self.mux.closed().cancelled() => {}
        }
    }

    async fn commands(
        &mut self,
        tx: &mut ServerSender,
        inbox: &mut mpsc::Receiver<ConnectRequest>,
    ) -> Status {
        let ended = || Status::new(Code::Unavailable, "host control stream ended");
        let mut retry = CLAIM_IDLE;
        loop {
            let body = json!({
                "registration_id": self.registration_id,
                "connection_epoch": self.epoch.to_string(),
            });
            let claimed = tokio::select! {
                claimed = self.gateway.call("claim_command", body, crate::control::CALL_TIMEOUT) => claimed,
                _ = self.gone() => return ended(),
            };
            let command = match claimed {
                Ok(None) => {
                    retry = CLAIM_IDLE;
                    tokio::select! {
                        _ = sleep(CLAIM_IDLE) => continue,
                        _ = self.gone() => return ended(),
                    }
                }
                Ok(Some(body)) => match pb::from_json::<ControllerCommand>(&body["command_json"]) {
                    Ok(command) => command,
                    Err(_) => {
                        tracing::warn!(
                            registration_id = self.registration_id,
                            "registration command claim failed"
                        );
                        return Status::new(Code::Unavailable, "control claim failed");
                    }
                },
                Err(error) if retryable_claim(&error) => {
                    self.gateway.count("control_error");
                    tracing::warn!(
                        registration_id = self.registration_id,
                        "registration command claim temporarily unavailable"
                    );
                    tokio::select! {
                        _ = sleep(retry) => {}
                        _ = self.gone() => return ended(),
                    }
                    retry = (retry * 2).min(CLAIM_RETRY_MAX);
                    continue;
                }
                Err(error) => {
                    tracing::warn!(registration_id = self.registration_id, %error, "registration command claim failed");
                    return Status::new(Code::Unavailable, "control claim failed");
                }
            };
            retry = CLAIM_IDLE;

            let (transcript, failure) = self.dispatch(command.clone(), tx, inbox).await;
            // The session is usable before Salix learns of it: Salix may call it
            // as soon as the result commits.
            let session = self.publish_session(&command, &transcript);
            let body = json!({
                "registration_id": self.registration_id, "transcript": transcript.to_json(),
            });
            if let Err(error) = self
                .gateway
                .call("commit_result", body, COMMIT_TIMEOUT)
                .await
            {
                self.gateway.count("control_error");
                tracing::warn!(registration_id = self.registration_id, command_id = command.command_id, %error, "registration command result commit failed");
                return Status::new(Code::Unavailable, "command result commit failed");
            }
            if let Some((key, session, header)) = session {
                self.observe_session(key, session, header).await;
            }
            if matches!(failure, Some(DispatchError::Unknown)) {
                self.gateway.count("unknown_outcome");
            }
            // A stale revision means Salix no longer has the Host's current
            // allocation facts. End the connection after the durable rejection, so
            // the next hello supplies a fresh bounded inventory. Ensure, release and
            // dispose also invalidate the hello's inventory fence, unless the
            // transcript proves that execution stopped before mutation.
            if requires_fresh_inventory(&command, transcript.result.as_ref()) {
                tracing::info!(
                    registration_id = self.registration_id,
                    command_id = command.command_id,
                    "registration command requires fresh inventory"
                );
                return Status::ok();
            }
            if let Some(DispatchError::Refused(reason)) = failure {
                tracing::warn!(
                    registration_id = self.registration_id,
                    command_id = command.command_id,
                    reason,
                    "registration command dispatch failed"
                );
                return Status::new(Code::Unknown, reason);
            }
        }
    }

    /// Sends one command and collects the Host's ack, evidence and result.
    async fn dispatch(
        &mut self,
        mut command: ControllerCommand,
        tx: &mut ServerSender,
        inbox: &mut mpsc::Receiver<ConnectRequest>,
    ) -> (Transcript, Option<DispatchError>) {
        let refused = |reason| (Transcript::default(), Some(DispatchError::Refused(reason)));
        if self.terminated.is_cancelled() {
            return refused("remote controller session is closed");
        }
        if command.command_id.is_empty() {
            return refused("command ID is required");
        }
        if command.connection_epoch == 0 {
            command.connection_epoch = self.epoch;
        }
        if command.sequence == 0 {
            command.sequence = self.last_sequence + 1;
        }
        if command.connection_epoch != self.epoch {
            return refused("command connection epoch does not match the current session");
        }
        if command.sequence != self.last_sequence + 1 {
            return refused("command sequence is not the next claimed sequence");
        }
        if command.timeout_millis == 0 {
            return refused("command context requires a future deadline");
        }
        let deadline = Instant::now() + Duration::from_millis(command.timeout_millis);
        let frame = ConnectResponse {
            payload: Some(connect_response::Payload::Command(command.clone())),
        };
        if tx.message(&frame.encode_to_vec()).await.is_err() {
            self.terminated.cancel();
            return refused("remote controller session is closed");
        }
        self.last_sequence = command.sequence;

        let mut transcript = Transcript::default();
        let identity = |id: &str, sequence: u64, epoch: u64| {
            id == command.command_id
                && sequence == command.sequence
                && epoch == command.connection_epoch
        };
        loop {
            let message = tokio::select! {
                biased;
                message = inbox.recv() => message,
                _ = sleep_until(deadline) => None,
            };
            let violation = match message.and_then(|message| message.payload) {
                // The stream ended or the deadline passed with the command admitted.
                None => false,
                Some(connect_request::Payload::Ack(ack)) => {
                    if ack.sequence < command.sequence {
                        continue;
                    }
                    if identity(&ack.command_id, ack.sequence, ack.connection_epoch) {
                        let rejected = ack.disposition == CommandAckDisposition::Rejected as i32;
                        if rejected {
                            transcript.result = Some(remote::CommandResult {
                                command_id: command.command_id.clone(),
                                sequence: command.sequence,
                                connection_epoch: command.connection_epoch,
                                outcome: CommandOutcome::Rejected as i32,
                                reason: ack.reason,
                                message: ack.message.clone(),
                                inventory_watermark: self.watermark,
                                ..Default::default()
                            });
                        }
                        transcript.ack = Some(ack);
                        if rejected {
                            return (transcript, None);
                        }
                        continue;
                    }
                    true
                }
                Some(connect_request::Payload::Evidence(evidence)) => {
                    if evidence.sequence < command.sequence {
                        continue;
                    }
                    if transcript.ack.is_some()
                        && identity(
                            &evidence.command_id,
                            evidence.sequence,
                            evidence.connection_epoch,
                        )
                    {
                        transcript.evidence.push(evidence);
                        continue;
                    }
                    true
                }
                Some(connect_request::Payload::Result(result)) => {
                    if result.sequence < command.sequence {
                        continue;
                    }
                    if transcript.ack.is_some()
                        && identity(&result.command_id, result.sequence, result.connection_epoch)
                    {
                        self.watermark = self.watermark.max(result.inventory_watermark);
                        transcript.result = Some(result);
                        return (transcript, None);
                    }
                    true
                }
                Some(_) => true,
            };
            if violation {
                self.terminated.cancel();
            }
            transcript.result = Some(remote::CommandResult {
                command_id: command.command_id.clone(),
                sequence: command.sequence,
                connection_epoch: command.connection_epoch,
                outcome: CommandOutcome::Unknown as i32,
                reason: ErrorReason::Unavailable as i32,
                message: "result lost after admission; read authoritative inventory".into(),
                inventory_watermark: self.watermark,
                ..Default::default()
            });
            return (transcript, Some(DispatchError::Unknown));
        }
    }

    /// A succeeded `OpenSession` binds the allocation's runtime calls to this
    /// connection, under the nonce the Host just issued.
    fn publish_session(
        &self,
        command: &ControllerCommand,
        transcript: &Transcript,
    ) -> Option<(SessionKey, Arc<RuntimeSession>, SessionHeader)> {
        let Some(Command::OpenSession(open)) = &command.command else {
            return None;
        };
        let result = transcript.result.as_ref()?;
        let Some(remote::command_result::Result::SessionReady(ready)) = &result.result else {
            return None;
        };
        if result.outcome != CommandOutcome::Succeeded as i32
            || ready.allocation_id != open.allocation_id
            || ready.allocation_generation != open.allocation_generation
            || ready.allocation_generation == 0
            || ready.tunnel_nonce.is_empty()
        {
            return None;
        }
        let key = SessionKey {
            registration_id: self.registration_id.to_owned(),
            allocation_id: ready.allocation_id.clone(),
            allocation_generation: ready.allocation_generation,
            connection_epoch: self.epoch,
        };
        let session = RuntimeSession::new(
            self.mux.clone(),
            &ready.allocation_id,
            ready.allocation_generation,
            &ready.tunnel_nonce,
            ready.expires_unix_millis,
        );
        self.gateway.insert_session(key.clone(), session.clone());
        let header = SessionHeader {
            registration_id: self.registration_id.to_owned(),
            allocation_id: ready.allocation_id.clone(),
            allocation_generation: ready.allocation_generation,
            tunnel_nonce: ready.tunnel_nonce.clone(),
            connection_epoch: self.epoch,
            expires_unix_millis: ready.expires_unix_millis,
        };
        Some((key, session, header))
    }

    async fn observe_session(
        &self,
        key: SessionKey,
        session: Arc<RuntimeSession>,
        header: SessionHeader,
    ) {
        let observed = match pb::to_json(&header) {
            Ok(header) => {
                let body = json!({"header_b64": STANDARD.encode(header.to_string())});
                self.gateway
                    .call("observe_session", body, crate::control::CALL_TIMEOUT)
                    .await
                    .is_ok()
            }
            Err(_) => false,
        };
        if observed {
            tracing::info!(
                registration_id = self.registration_id,
                allocation_id = key.allocation_id,
                allocation_generation = key.allocation_generation,
                "host session ready"
            );
        } else {
            // Salix holds no session row: reconciliation opens a fresh one.
            self.gateway.count("control_error");
            self.gateway.remove_session(&key, &session);
            tracing::warn!(
                registration_id = self.registration_id,
                allocation_id = key.allocation_id,
                "host session observation failed"
            );
        }
    }
}

/// Reads the Host's frames after readiness: command evidence for the dispatch
/// in flight, and observation renewals, of which only the latest is settled.
async fn receive(
    mut rx: ServerReceiver,
    epoch: u64,
    messages: mpsc::Sender<ConnectRequest>,
    observations: watch::Sender<Option<RemoteObservationRenewal>>,
    terminated: CancellationToken,
) {
    let _terminate = terminated.drop_guard();
    while let Ok(Some(bytes)) = rx.message().await {
        let Ok(message) = ConnectRequest::decode(bytes.as_slice()) else {
            return;
        };
        match &message.payload {
            Some(connect_request::Payload::ObservationRenewal(renewal)) => {
                let valid = renewal.connection_epoch == epoch
                    && renewal.observation.as_ref().is_some_and(|observation| {
                        observation.sequence >= 2
                            && observation.observed_unix_millis > 0
                            && observation.inventory_observed_unix_millis > 0
                    });
                if !valid {
                    return;
                }
                let _ = observations.send(Some(renewal.clone()));
            }
            // Reachability is published through the registry; the renewal only
            // has to belong to this connection.
            Some(connect_request::Payload::EndpointObservationRenewal(renewal)) => {
                if renewal.connection_epoch != epoch || renewal.endpoint_observation.is_none() {
                    return;
                }
            }
            Some(
                connect_request::Payload::Ack(_)
                | connect_request::Payload::Evidence(_)
                | connect_request::Payload::Result(_),
            ) => {
                if messages.try_send(message).is_err() {
                    return;
                }
            }
            _ => return,
        }
    }
}

fn changes_inventory(command: &ControllerCommand) -> bool {
    matches!(
        command.command,
        Some(
            Command::EnsureAllocation(_)
                | Command::ReleaseAllocation(_)
                | Command::DisposeAllocation(_)
        )
    )
}

pub fn requires_fresh_inventory(
    command: &ControllerCommand,
    result: Option<&remote::CommandResult>,
) -> bool {
    let outcome =
        |result: &remote::CommandResult, outcome: CommandOutcome| result.outcome == outcome as i32;
    let reason =
        |result: &remote::CommandResult, reason: ErrorReason| result.reason == reason as i32;
    if matches!(command.command, Some(Command::DisposeAllocation(_))) {
        return result.is_some_and(|result| outcome(result, CommandOutcome::Succeeded));
    }
    if let Some(result) = result
        && outcome(result, CommandOutcome::Rejected)
        && (reason(result, ErrorReason::StaleRevision)
            || reason(result, ErrorReason::DisposalRevisionNotAccepted))
    {
        return true;
    }
    if !changes_inventory(command) {
        return false;
    }
    let Some(result) = result else {
        return true;
    };
    !matches!(command.command, Some(Command::EnsureAllocation(_)))
        || !outcome(result, CommandOutcome::Rejected)
        || (!reason(result, ErrorReason::CapacityExhausted)
            && !reason(result, ErrorReason::AdmissionPaused))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pb::remote::{
        CommandResult, DisposeAllocation, EnsureAllocation, OpenSession, ReleaseAllocation,
    };

    fn command(command: Command) -> ControllerCommand {
        ControllerCommand {
            command_id: "command".into(),
            command: Some(command),
            ..Default::default()
        }
    }

    fn result(outcome: CommandOutcome, reason: ErrorReason) -> CommandResult {
        CommandResult {
            outcome: outcome as i32,
            reason: reason as i32,
            ..Default::default()
        }
    }

    #[test]
    fn inventory_changing_outcomes_force_a_fresh_handshake() {
        let ensure = command(Command::EnsureAllocation(EnsureAllocation::default()));
        let release = command(Command::ReleaseAllocation(ReleaseAllocation::default()));
        let dispose = command(Command::DisposeAllocation(DisposeAllocation::default()));
        let open = command(Command::OpenSession(OpenSession::default()));
        let ok = result(CommandOutcome::Succeeded, ErrorReason::Unspecified);
        let rejected = |reason| result(CommandOutcome::Rejected, reason);

        assert!(requires_fresh_inventory(&ensure, Some(&ok)));
        assert!(requires_fresh_inventory(&ensure, None));
        assert!(requires_fresh_inventory(
            &ensure,
            Some(&result(CommandOutcome::Unknown, ErrorReason::Unavailable))
        ));
        assert!(requires_fresh_inventory(
            &ensure,
            Some(&rejected(ErrorReason::PolicyConflict))
        ));
        // Admission refused before any mutation: the same connection continues.
        assert!(!requires_fresh_inventory(
            &ensure,
            Some(&rejected(ErrorReason::CapacityExhausted))
        ));
        assert!(!requires_fresh_inventory(
            &ensure,
            Some(&rejected(ErrorReason::AdmissionPaused))
        ));
        assert!(requires_fresh_inventory(
            &release,
            Some(&rejected(ErrorReason::CapacityExhausted))
        ));
        assert!(requires_fresh_inventory(&dispose, Some(&ok)));
        assert!(!requires_fresh_inventory(
            &dispose,
            Some(&rejected(ErrorReason::StaleRevision))
        ));
        assert!(!requires_fresh_inventory(&dispose, None));
        assert!(!requires_fresh_inventory(&open, Some(&ok)));
        assert!(requires_fresh_inventory(
            &open,
            Some(&rejected(ErrorReason::StaleRevision))
        ));
        assert!(requires_fresh_inventory(
            &open,
            Some(&rejected(ErrorReason::DisposalRevisionNotAccepted))
        ));
    }

    #[test]
    fn identity_takes_one_registration_and_a_padded_bearer() {
        let header = |metadata: &[(&str, &str)]| RequestHeader {
            v: 1,
            method: String::new(),
            metadata: metadata
                .iter()
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .collect(),
            timeout_ms: None,
        };
        let bearer = format!("Bearer {}", STANDARD.encode([7u8; 16]));
        let (id, credential) = remote_identity(&header(&[
            ("authorization", &bearer),
            ("x-agentvmm-registration-id", "reg"),
        ]))
        .unwrap();
        assert_eq!((id.as_str(), credential.len()), ("reg", 16));
        assert!(
            remote_identity(&header(&[
                ("authorization", &bearer),
                ("x-agent-vmm-registration", "reg")
            ]))
            .is_ok()
        );

        let code = |metadata: &[(&str, &str)]| remote_identity(&header(metadata)).unwrap_err();
        assert_eq!(
            code(&[("authorization", &bearer)]).message,
            "remote credential required"
        );
        assert_eq!(
            code(&[
                ("authorization", &bearer),
                ("x-agentvmm-registration-id", "a"),
                ("x-agent-vmm-registration", "b")
            ])
            .message,
            "remote credential required"
        );
        let unpadded = bearer.trim_end_matches('=').to_owned();
        for invalid in [unpadded.as_str(), "Basic abc", "Bearer c2hvcnQ="] {
            assert_eq!(
                code(&[
                    ("authorization", invalid),
                    ("x-agentvmm-registration-id", "reg")
                ])
                .message,
                "remote credential invalid"
            );
        }
    }

    #[test]
    fn hello_outside_protocol_five_is_refused_with_its_range() {
        let mut hello = HostHello {
            protocol_version: "4".into(),
            registration_id: "reg".into(),
            connection_epoch: 9,
            inventory_watermark: 1,
            ..Default::default()
        };
        let refused = validate_hello(&hello, "reg").unwrap_err();
        assert_eq!(refused.code, Code::FailedPrecondition);
        let info = &refused.error_infos()[0];
        assert_eq!(
            (info.domain.as_str(), info.reason.as_str()),
            ("agent-vmm", "REMOTE_PROTOCOL_UNSUPPORTED")
        );
        assert_eq!(info.metadata["host_side"], "too_old");
        assert_eq!(
            (
                info.metadata["min_protocol"].as_str(),
                info.metadata["max_protocol"].as_str()
            ),
            ("5", "5")
        );
        hello.protocol_version = "6".into();
        assert_eq!(
            validate_hello(&hello, "reg").unwrap_err().error_infos()[0].metadata["host_side"],
            "too_new"
        );
        hello.protocol_version = "5".into();
        assert!(validate_hello(&hello, "reg").is_ok());
        assert!(validate_hello(&hello, "other").is_err());
        hello.inventory_watermark = 0;
        assert!(validate_hello(&hello, "reg").is_err());
    }
}
