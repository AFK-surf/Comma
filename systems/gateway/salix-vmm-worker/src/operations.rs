//! The typed runtime operations Salix Compute may run in a session. Each name
//! is one bounded operation: a caller cannot reach an arbitrary Host RPC.

use crate::{
    json::{self, Args},
    pb::{self, host, service, trust},
    rpc::{self, ClientCall, ClientReceiver},
    runtime_error::OpError,
    session::{
        MAX_PROCESSES, MAX_START_REQUESTS, OUTPUT_BOUND, ProcessState, Processes, RuntimeProcess,
        RuntimeSession, StartRecord,
    },
    status::{Code, Status},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use prost::{Message, Name};
use serde_json::{Value, json};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::time::Instant;

/// One typed operation's bound.
const OPERATION_TIMEOUT: Duration = Duration::from_secs(90);
/// How long the Host may keep an execution this side started.
const RUNTIME_OPERATION_BUDGET: Duration = Duration::from_secs(30 * 60);
const MEBIBYTE: usize = 1 << 20;
const WORKSPACE_CHUNK_BYTES: usize = 64 * 1024;
const MAX_TAIL_WAIT_MS: u64 = 30_000;
const DEFAULT_EXEC_TIMEOUT_MS: u64 = 60_000;
const MIN_EXEC_TIMEOUT_MS: u64 = 1_000;
const MAX_EXEC_TIMEOUT_MS: u64 = 300_000;
const EXEC_DEADLINE_GRACE_MS: u64 = 15_000;
const DEFAULT_WORKSPACE_LIST_LIMIT: u32 = 100;
const MAX_WORKSPACE_LIST_LIMIT: u32 = 500;

/// The Host operation behind a typed operation that needs no preparation here.
fn host_operation(operation: &str) -> Option<&'static str> {
    Some(match operation {
        "compute.workspace.stat" => "workspace_stat",
        "compute.workspace.list" => "workspace_list",
        "compute.workspace.read" => "workspace_read",
        "compute.workspace.write" => "workspace_write",
        "compute.image.list" => "image_list",
        "compute.image.delete" => "image_delete",
        "compute.volume.create" => "volume_create",
        "compute.volume.get" => "volume_get",
        "compute.volume.list" => "volume_list",
        "compute.volume.delete" => "volume_delete",
        "compute.container.create" => "container_create",
        "compute.container.start" => "container_start",
        "compute.container.stop" => "container_stop",
        "compute.container.get" => "container_get",
        "compute.container.list" => "container_list",
        "compute.container.delete" => "container_delete",
        "compute.container.logs" => "container_logs",
        "compute.execution.acquire" => "execution_acquire",
        "compute.execution.release" => "execution_release",
        "compute.execution.list" => "execution_list",
        "compute.container.quiesce" => "container_quiesce",
        "compute.forward.tcp" => "forward_tcp",
        "compute.service.export" => "service_export",
        "compute.service.import" => "service_import",
        "compute.route.revoke" => "route_revoke",
        _ => return None,
    })
}

pub fn is_typed_operation(operation: &str) -> bool {
    matches!(
        operation,
        "compute.exec"
            | "compute.container.exec"
            | "compute.build.run"
            | "process.start"
            | "process.list"
            | "process.write"
            | "process.tail"
            | "process.stop"
    ) || host_operation(operation).is_some()
}

struct Runtime<'a> {
    session: &'a RuntimeSession,
    deadline: Option<Instant>,
}

impl Runtime<'_> {
    async fn open(&self, method: &str) -> Result<ClientCall, OpError> {
        Ok(self.session.call(method, self.deadline).await?)
    }

    async fn unary<Request: Message, Response: Message + Default>(
        &self,
        method: &str,
        request: &Request,
    ) -> Result<Response, OpError> {
        let mut call = self.open(method).await?;
        call.tx.send(request).await?;
        call.tx.close().await?;
        Ok(single(&mut call.rx).await?)
    }
}

/// The one response of a call.
async fn single<Response: Message + Default>(rx: &mut ClientReceiver) -> Result<Response, Status> {
    let response = rx
        .message::<Response>()
        .await?
        .ok_or_else(|| Status::new(Code::Internal, "response message required"))?;
    match rx.message::<Response>().await? {
        None => Ok(response),
        Some(_) => Err(Status::new(Code::Internal, "unexpected response message")),
    }
}

fn proto_json<M: Message + Name>(message: &M) -> Result<Value, OpError> {
    pb::to_proto_name_json(message).map_err(|_| OpError::Local("response encoding failed"))
}

fn decode_base64(args: &Args, key: &str) -> Option<Vec<u8>> {
    STANDARD.decode(json::string(args, key)).ok()
}

fn resolve_exec_timeout_ms(args: &Args) -> u64 {
    let raw = json::uint64(args, "timeout_ms", 0);
    if raw == 0 {
        DEFAULT_EXEC_TIMEOUT_MS
    } else {
        raw.clamp(MIN_EXEC_TIMEOUT_MS, MAX_EXEC_TIMEOUT_MS)
    }
}

pub async fn execute(
    session: &Arc<RuntimeSession>,
    operation: &str,
    args: &Args,
) -> Result<Value, OpError> {
    let runtime = Runtime {
        session,
        deadline: Some(Instant::now() + OPERATION_TIMEOUT),
    };
    let request_id = json::string(args, "request_id");
    match operation {
        "compute.exec" => {
            let timeout_ms = resolve_exec_timeout_ms(args);
            let exec_runtime = Runtime {
                session,
                deadline: Some(
                    Instant::now() + Duration::from_millis(timeout_ms + EXEC_DEADLINE_GRACE_MS),
                ),
            };
            let execution = format!("exec:{request_id}");
            let mut forwarded =
                prepare_execution(&exec_runtime, args, execution, host::ExecutionKind::Exec)
                    .await?;
            forwarded.insert("argv".into(), json!(json::string_list(args, "command")));
            forwarded.insert("timeout_ms".into(), json!(timeout_ms));
            host_call(&exec_runtime, "container_exec", &forwarded).await
        }
        "compute.container.exec" => {
            let execution = format!("exec:{request_id}");
            let forwarded =
                prepare_execution(&runtime, args, execution, host::ExecutionKind::Exec).await?;
            let requested = json::string(args, "container_id");
            if !requested.is_empty() && requested != json::string(&forwarded, "container_id") {
                return Err(OpError::Local("exec container target is controller-owned"));
            }
            host_call(&runtime, "container_exec", &forwarded).await
        }
        "compute.build.run" => {
            let execution = format!("build:{request_id}");
            let forwarded =
                prepare_execution(&runtime, args, execution, host::ExecutionKind::Build).await?;
            host_call(&runtime, "build_run", &forwarded).await
        }
        "process.start" => start_process(session, &runtime, args).await,
        "process.list" => Ok(list_processes(session)),
        "process.write" => write_process(session, args).await,
        "process.tail" => tail_process(session, args).await,
        "process.stop" => stop_process(session, args).await,
        other => match host_operation(other) {
            Some(operation) => host_call(&runtime, operation, args).await,
            None => Err(OpError::Local("unsupported typed runtime operation")),
        },
    }
}

/// The compute runtime's one running container and its current instance.
async fn container_target(runtime: &Runtime<'_>) -> Result<(String, String), OpError> {
    let response: host::GetEnvironmentResponse = runtime
        .unary("GetEnvironment", &host::GetEnvironmentRequest {})
        .await?;
    let running: Vec<host::Container> = response
        .environment
        .unwrap_or_default()
        .containers
        .into_iter()
        .filter(|container| container.state == host::ContainerState::Running as i32)
        .collect();
    match running.as_slice() {
        [container] if !container.id.is_empty() && !container.instance_id.is_empty() => {
            Ok((container.id.clone(), container.instance_id.clone()))
        }
        _ => Err(OpError::Local(
            "compute runtime must have exactly one running container instance",
        )),
    }
}

/// Binds an execution to the container instance that is current now. The
/// controller owns the target: a caller's own container fields are replaced.
async fn prepare_execution(
    runtime: &Runtime<'_>,
    args: &Args,
    execution_id: String,
    kind: host::ExecutionKind,
) -> Result<Args, OpError> {
    if execution_id.is_empty() || execution_id.ends_with(':') {
        return Err(OpError::Local("runtime operation request_id is required"));
    }
    let (container_id, instance_id) = container_target(runtime).await?;
    let deadline = SystemTime::now() + RUNTIME_OPERATION_BUDGET;
    let deadline = deadline
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as i64)
        .unwrap_or_default();
    let mut forwarded = args.clone();
    forwarded.insert("container_id".into(), json!(container_id));
    forwarded.insert("expected_instance_id".into(), json!(instance_id));
    forwarded.insert("execution_id".into(), json!(execution_id));
    forwarded.insert("execution_kind".into(), json!(kind as i32));
    forwarded.insert("execution_deadline_unix_nano".into(), json!(deadline));
    Ok(forwarded)
}

fn execution_kind(args: &Args) -> host::ExecutionKind {
    match json::string(args, "kind").as_str() {
        "main_execution" => host::ExecutionKind::MainExecution,
        "auth_operation" => host::ExecutionKind::AuthOperation,
        "migration_export" => host::ExecutionKind::MigrationExport,
        "migration_import" => host::ExecutionKind::MigrationImport,
        "exec" => host::ExecutionKind::Exec,
        "process" => host::ExecutionKind::Process,
        "build" => host::ExecutionKind::Build,
        _ => host::ExecutionKind::Unspecified,
    }
}

fn exec_start(args: &Args, argv: Vec<String>, kind: i32) -> host::ExecStart {
    host::ExecStart {
        request_id: json::string(args, "request_id"),
        container_id: json::string(args, "container_id"),
        argv,
        env: json::string_list(args, "env"),
        workdir: json::optional_string(args, "workdir"),
        user: json::optional_string(args, "user"),
        tty: false,
        expected_instance_id: json::string(args, "expected_instance_id"),
        execution_id: json::string(args, "execution_id"),
        execution_kind: kind,
        execution_deadline_unix_nano: json::int64(args, "execution_deadline_unix_nano", 0),
        timeout_ms: json::uint64(args, "timeout_ms", 0),
        ..Default::default()
    }
}

fn container_create_request(args: &Args) -> host::CreateContainerRequest {
    let list = |key: &str| {
        Some(json::string_list(args, key))
            .filter(|values| !values.is_empty())
            .map(|values| host::StringList { values })
    };
    host::CreateContainerRequest {
        request_id: json::string(args, "request_id"),
        container_id: json::string(args, "container_id"),
        image: json::string(args, "image"),
        env: json::string_list(args, "env"),
        read_only_root: json::boolean(args, "read_only_root"),
        log_limit_bytes: json::uint64(args, "log_limit_bytes", 0),
        entrypoint_override: list("entrypoint"),
        command_override: list("command"),
        workdir: json::optional_string(args, "workdir"),
        user: json::optional_string(args, "user"),
        volumes: json::map_list(args, "volumes")
            .into_iter()
            .map(|volume| host::VolumeMount {
                source: Some(host::volume_mount::Source::OwnedVolume(json::string(
                    volume,
                    "volume_id",
                ))),
                destination: json::string(volume, "destination"),
                read_only: json::boolean(volume, "read_only"),
            })
            .collect(),
        ..Default::default()
    }
}

async fn host_call(runtime: &Runtime<'_>, operation: &str, args: &Args) -> Result<Value, OpError> {
    let text = |key: &str| json::string(args, key);
    match operation {
        "image_list" => {
            let response: host::ListImagesResponse = runtime
                .unary("ListImages", &host::ListImagesRequest::default())
                .await?;
            proto_json(&response)
        }
        "image_delete" => {
            let request = host::DeleteImageRequest {
                request_id: text("request_id"),
                reference: text("reference"),
                expected_generation_id: text("expected_generation_id"),
                expected_digest: text("expected_digest"),
                ..Default::default()
            };
            let response: host::DeleteImageResponse =
                runtime.unary("DeleteImage", &request).await?;
            proto_json(&response)
        }
        "volume_create" => {
            let request = host::CreateVolumeRequest {
                request_id: text("request_id"),
                volume_id: text("volume_id"),
                owner_uid: json::optional_uint32(args, "owner_uid"),
                owner_gid: json::optional_uint32(args, "owner_gid"),
                mode: json::optional_uint32(args, "mode"),
            };
            let response: host::CreateVolumeResponse =
                runtime.unary("CreateVolume", &request).await?;
            proto_json(&response)
        }
        "volume_get" => {
            let request = host::GetVolumeRequest {
                volume_id: text("volume_id"),
            };
            let response: host::GetVolumeResponse = runtime.unary("GetVolume", &request).await?;
            proto_json(&response)
        }
        "volume_list" => {
            let response: host::ListVolumesResponse = runtime
                .unary("ListVolumes", &host::ListVolumesRequest {})
                .await?;
            proto_json(&response)
        }
        "volume_delete" => {
            let request = host::DeleteVolumeRequest {
                request_id: text("request_id"),
                volume_id: text("volume_id"),
            };
            let response: host::DeleteVolumeResponse =
                runtime.unary("DeleteVolume", &request).await?;
            proto_json(&response)
        }
        "container_create" => {
            let response: host::CreateContainerResponse = runtime
                .unary("CreateContainer", &container_create_request(args))
                .await?;
            proto_json(&response)
        }
        "container_start" => {
            let request = host::StartContainerRequest {
                request_id: text("request_id"),
                container_id: text("container_id"),
                expected_generation_id: text("expected_generation_id"),
            };
            let response: host::StartContainerResponse =
                runtime.unary("StartContainer", &request).await?;
            proto_json(&response)
        }
        "container_stop" => {
            let request = host::StopContainerRequest {
                request_id: text("request_id"),
                container_id: text("container_id"),
                timeout_seconds: json::optional_uint32(args, "timeout_seconds"),
                expected_instance_id: text("expected_instance_id"),
                quiesce_request_id: text("quiesce_request_id"),
            };
            let response: host::StopContainerResponse =
                runtime.unary("StopContainer", &request).await?;
            proto_json(&response)
        }
        "execution_acquire" => {
            let request = host::AcquireExecutionRequest {
                execution_id: text("execution_id"),
                container_id: text("container_id"),
                expected_instance_id: text("expected_instance_id"),
                deadline_unix_nano: json::uint64(args, "deadline_unix_nano", 0) as i64,
                holder_id: text("holder_id"),
                kind: execution_kind(args) as i32,
            };
            let response: host::AcquireExecutionResponse =
                runtime.unary("AcquireExecution", &request).await?;
            proto_json(&response)
        }
        "execution_release" => {
            let request = host::ReleaseExecutionRequest {
                execution_id: text("execution_id"),
                container_id: text("container_id"),
                expected_instance_id: text("expected_instance_id"),
                holder_id: text("holder_id"),
                ..Default::default()
            };
            let _: host::ReleaseExecutionResponse =
                runtime.unary("ReleaseExecution", &request).await?;
            Ok(json!({"released": true}))
        }
        "execution_list" => {
            let request = host::ListExecutionsRequest {
                container_id: text("container_id"),
                expected_instance_id: text("expected_instance_id"),
            };
            let response: host::ListExecutionsResponse =
                runtime.unary("ListExecutions", &request).await?;
            proto_json(&response)
        }
        "container_quiesce" => {
            let request = host::QuiesceContainerRequest {
                request_id: text("request_id"),
                container_id: text("container_id"),
                expected_instance_id: text("expected_instance_id"),
                cancel: json::boolean(args, "cancel"),
                minimum_idle_seconds: json::uint32(args, "minimum_idle_seconds", 0),
            };
            let response: host::QuiesceContainerResponse =
                runtime.unary("QuiesceContainer", &request).await?;
            proto_json(&response)
        }
        "container_get" => {
            let request = host::GetContainerRequest {
                container_id: text("container_id"),
                ..Default::default()
            };
            let response: host::GetContainerResponse =
                runtime.unary("GetContainer", &request).await?;
            proto_json(&response)
        }
        "container_list" => {
            let response: host::ListContainersResponse = runtime
                .unary("ListContainers", &host::ListContainersRequest {})
                .await?;
            proto_json(&response)
        }
        "container_delete" => {
            let request = host::DeleteContainerRequest {
                request_id: text("request_id"),
                container_id: text("container_id"),
                expected_generation_id: text("expected_generation_id"),
            };
            let response: host::DeleteContainerResponse =
                runtime.unary("DeleteContainer", &request).await?;
            proto_json(&response)
        }
        "container_logs" => {
            let request = host::LogsRequest {
                container_id: text("container_id"),
                tail_records: json::uint64(args, "tail_records", 100),
                after_cursor: text("after_cursor"),
                follow: false,
                ..Default::default()
            };
            let limit = json::uint64(args, "limit", 1000);
            let mut call = runtime.open("Logs").await?;
            call.tx.send(&request).await?;
            call.tx.close().await?;
            let mut records = Vec::new();
            while (records.len() as u64) < limit {
                match call.rx.message::<host::LogsResponse>().await? {
                    Some(record) => records.push(proto_json(&record)?),
                    None => break,
                }
            }
            Ok(json!({"records": records}))
        }
        "container_exec" => {
            let kind = json::int64(args, "execution_kind", 0) as i32;
            let start = exec_start(args, json::string_list(args, "argv"), kind);
            let stdin = decode_base64(args, "stdin_base64")
                .ok_or(OpError::Local("exec stdin is invalid"))?;
            let ClientCall { mut tx, mut rx } = runtime.open("Exec").await?;
            let send = async {
                tx.send(&exec_request(host::exec_request::Event::Start(start)))
                    .await?;
                if !stdin.is_empty() {
                    tx.send(&exec_request(host::exec_request::Event::Stdin(stdin)))
                        .await?;
                }
                tx.send(&exec_request(host::exec_request::Event::CloseStdin(true)))
                    .await?;
                tx.close().await
            };
            let output = async {
                let (mut stdout, mut stderr, mut exit_code) = (Vec::new(), Vec::new(), 0u32);
                let (mut timed_out, mut oom_killed, mut memory_peak_bytes) = (false, false, None);
                while let Some(response) = rx.message::<host::ExecResponse>().await? {
                    match response.event {
                        Some(host::exec_response::Event::Stdout(bytes)) => stdout.extend(bytes),
                        Some(host::exec_response::Event::Stderr(bytes)) => stderr.extend(bytes),
                        Some(host::exec_response::Event::ExitCode(code)) => {
                            exit_code = code;
                            timed_out = response.timed_out;
                            oom_killed = response.oom_killed;
                            memory_peak_bytes = response.memory_peak_bytes;
                        }
                        None => {}
                    }
                    if stdout.len() + stderr.len() > OUTPUT_BOUND {
                        return Err(OpError::Local("exec output exceeds bound"));
                    }
                }
                Ok((
                    stdout,
                    stderr,
                    exit_code,
                    timed_out,
                    oom_killed,
                    memory_peak_bytes,
                ))
            };
            let (stdout, stderr, exit_code, timed_out, oom_killed, memory_peak_bytes) =
                rpc::exchange(send, output).await?;
            let mut result = json!({
                "stdout_base64": STANDARD.encode(stdout),
                "stderr_base64": STANDARD.encode(stderr),
                "exit_code": exit_code,
                "timed_out": timed_out,
                "oom_killed": oom_killed,
            });
            if let Some(peak) = memory_peak_bytes {
                result["memory_peak_bytes"] = json!(peak);
            }
            Ok(result)
        }
        "forward_tcp" => {
            let payload = decode_base64(args, "data_base64")
                .filter(|payload| payload.len() <= OUTPUT_BOUND)
                .ok_or(OpError::Local("forward payload is invalid or too large"))?;
            let event = |event| host::ForwardTcpRequest { event: Some(event) };
            let header = host::ForwardTcpHeader {
                container_id: text("container_id"),
                container_instance_id: text("container_instance_id"),
                port: json::uint32(args, "port", 0),
            };
            let ClientCall { mut tx, mut rx } = runtime.open("ForwardTCP").await?;
            let send = async {
                tx.send(&event(host::forward_tcp_request::Event::Header(header)))
                    .await?;
                if !payload.is_empty() {
                    tx.send(&event(host::forward_tcp_request::Event::Data(payload)))
                        .await?;
                }
                tx.send(&event(host::forward_tcp_request::Event::CloseWrite(true)))
                    .await?;
                tx.close().await
            };
            let answer = async {
                let mut received = Vec::new();
                while let Some(response) = rx.message::<host::ForwardTcpResponse>().await? {
                    match response.event {
                        Some(host::forward_tcp_response::Event::CloseRead(true)) => break,
                        Some(host::forward_tcp_response::Event::Data(bytes)) => {
                            received.extend(bytes)
                        }
                        _ => {}
                    }
                    if received.len() > OUTPUT_BOUND {
                        return Err(OpError::Local("forward response exceeds bound"));
                    }
                }
                Ok(received)
            };
            let received = rpc::exchange(send, answer).await?;
            Ok(json!({"data_base64": STANDARD.encode(received)}))
        }
        "workspace_stat" => {
            let request = host::StatWorkspaceRequest { path: text("path") };
            let response: host::StatWorkspaceResponse =
                runtime.unary("StatWorkspace", &request).await?;
            proto_json(&response.entry.unwrap_or_default())
        }
        "workspace_list" => {
            let limit = json::uint32(args, "limit", DEFAULT_WORKSPACE_LIST_LIMIT)
                .clamp(1, MAX_WORKSPACE_LIST_LIMIT);
            let request = host::ListWorkspaceRequest {
                path: text("path"),
                limit,
                volume_id: text("volume_id"),
                cursor: text("cursor"),
            };
            let response: host::ListWorkspaceResponse =
                runtime.unary("ListWorkspace", &request).await?;
            let entries: Result<Vec<Value>, OpError> = response
                .entries
                .iter()
                .map(|entry| {
                    let mut value = proto_json(entry)?;
                    if let Some(obj) = value.as_object_mut()
                        && obj.get("sha256").and_then(Value::as_str) == Some("")
                    {
                        obj.remove("sha256");
                    }
                    Ok(value)
                })
                .collect();
            let next_cursor = if response.next_cursor.is_empty() {
                Value::Null
            } else {
                Value::String(response.next_cursor)
            };
            Ok(json!({
                "entries": entries?,
                "has_more": response.has_more,
                "next_cursor": next_cursor,
            }))
        }
        "workspace_read" => {
            let request = host::ReadWorkspaceRequest {
                path: text("path"),
                offset: json::uint64(args, "offset", 0),
                max_bytes: json::uint64(args, "max_bytes", MEBIBYTE as u64),
                volume_id: text("volume_id"),
            };
            let mut call = runtime.open("ReadWorkspace").await?;
            call.tx.send(&request).await?;
            call.tx.close().await?;
            let (mut data, mut digest) = (Vec::new(), Vec::new());
            while let Some(chunk) = call.rx.message::<host::ReadWorkspaceResponse>().await? {
                if data.len() + chunk.data.len() > MEBIBYTE {
                    return Err(OpError::Local("workspace read exceeds bound"));
                }
                data.extend(chunk.data);
                digest = chunk.sha256;
            }
            Ok(json!({
                "content_base64": STANDARD.encode(data), "sha256": STANDARD.encode(digest),
            }))
        }
        "workspace_write" => {
            let content = decode_base64(args, "content_base64")
                .filter(|content| content.len() <= MEBIBYTE)
                .ok_or(OpError::Local("workspace content is invalid or too large"))?;
            let expected = decode_base64(args, "expected_prefix_sha256")
                .ok_or(OpError::Local("workspace prefix digest is invalid"))?;
            let payload = |payload| host::WriteWorkspaceRequest {
                payload: Some(payload),
            };
            let header = host::WriteWorkspaceHeader {
                request_id: text("request_id"),
                path: text("path"),
                offset: json::uint64(args, "offset", 0),
                expected_prefix_sha256: expected,
                mode: json::uint32(args, "mode", 0o644),
                volume_id: text("volume_id"),
            };
            let ClientCall { mut tx, mut rx } = runtime.open("WriteWorkspace").await?;
            let send = async {
                tx.send(&payload(host::write_workspace_request::Payload::Header(
                    header,
                )))
                .await?;
                // The Host refuses a data frame above its chunk bound.
                for part in content.chunks(WORKSPACE_CHUNK_BYTES) {
                    tx.send(&payload(host::write_workspace_request::Payload::Data(
                        part.to_vec(),
                    )))
                    .await?;
                }
                tx.send(&payload(host::write_workspace_request::Payload::Finish(
                    true,
                )))
                .await?;
                tx.close().await
            };
            let response: host::WriteWorkspaceResponse =
                rpc::exchange(send, single(&mut rx)).await?;
            proto_json(&response)
        }
        "build_run" => {
            let context = decode_base64(args, "context_base64")
                .filter(|context| context.len() <= OUTPUT_BOUND)
                .ok_or(OpError::Local("build context is invalid or too large"))?;
            let event = |event| host::BuildImageRequest { event: Some(event) };
            let header = host::BuildImageHeader {
                request_id: text("request_id"),
                dockerfile_path: text("dockerfile_path"),
                image: text("image"),
                network_mode: host::BuildNetworkMode::None as i32,
                container_id: text("container_id"),
                expected_instance_id: text("expected_instance_id"),
                execution_id: text("execution_id"),
                execution_deadline_unix_nano: json::int64(args, "execution_deadline_unix_nano", 0),
                ..Default::default()
            };
            let chunk = host::BuildContextChunk {
                data: context,
                r#final: true,
            };
            let ClientCall { mut tx, mut rx } = runtime.open("BuildImage").await?;
            let send = async {
                tx.send(&event(host::build_image_request::Event::Header(header)))
                    .await?;
                tx.send(&event(host::build_image_request::Event::Context(chunk)))
                    .await?;
                tx.close().await
            };
            let answer = async {
                let mut result = None;
                while let Some(response) = rx.message::<host::BuildImageResponse>().await? {
                    if let Some(host::build_image_response::Event::Result(value)) = response.event {
                        result = Some(value);
                    }
                }
                Ok::<_, Status>(result)
            };
            let result = rpc::exchange(send, answer).await?;
            proto_json(&result.ok_or(OpError::Local("build completed without result"))?)
        }
        "service_export" => {
            let request = host::CreateServiceExportRequest {
                request_id: text("request_id"),
                container_id: text("container_id"),
                container_instance_id: text("container_instance_id"),
                port: json::uint32(args, "port", 0),
                protocol: service::ServiceProtocol::Tcp as i32,
            };
            let response: host::CreateServiceExportResponse =
                runtime.unary("CreateServiceExport", &request).await?;
            proto_json(&response.export.unwrap_or_default())
        }
        "service_import" => {
            let request = host::CreatePersonalServiceImportRequest {
                request_id: text("request_id"),
                mesh_id: text("mesh_id"),
                source_container_id: text("source_container_id"),
                source_container_instance_id: text("source_container_instance_id"),
                destination_device_id: text("destination_device_id"),
                destination_export_id: text("destination_export_id"),
                virtual_service_name: text("virtual_service_name"),
                budget: Some(trust::RouteBudget {
                    connection_limit: json::uint32(args, "connection_limit", 1),
                    concurrency_limit: json::uint32(args, "concurrency_limit", 1),
                    byte_limit: json::uint64(args, "byte_limit", MEBIBYTE as u64),
                }),
            };
            let response: host::CreatePersonalServiceImportResponse = runtime
                .unary("CreatePersonalServiceImport", &request)
                .await?;
            proto_json(&response.import.unwrap_or_default())
        }
        "route_revoke" => {
            let request = host::RevokeServiceImportRequest {
                request_id: text("request_id"),
                import_id: text("import_id"),
                expected_revision: json::uint64(args, "expected_revision", 0),
            };
            let _: host::RevokeServiceImportResponse =
                runtime.unary("RevokeServiceImport", &request).await?;
            Ok(json!({"revoked": true}))
        }
        _ => Err(OpError::Local("unsupported host operation")),
    }
}

fn exec_request(event: host::exec_request::Event) -> host::ExecRequest {
    host::ExecRequest { event: Some(event) }
}

// ---- long-lived processes ----------------------------------------------------

/// Everything of a start but its two identities.
fn start_fingerprint(args: &Args) -> String {
    let mut fingerprint = args.clone();
    fingerprint.remove("request_id");
    fingerprint.remove("process_id");
    json::canonical(&Value::Object(fingerprint))
}

struct StartSlot<'a>(&'a Mutex<Processes>);

impl Drop for StartSlot<'_> {
    fn drop(&mut self) {
        let mut processes = self.0.lock().expect("processes");
        processes.starting = processes.starting.saturating_sub(1);
    }
}

async fn start_process(
    session: &Arc<RuntimeSession>,
    runtime: &Runtime<'_>,
    args: &Args,
) -> Result<Value, OpError> {
    const CLOSED: OpError = OpError::Local("runtime session is closed");
    let request_id = json::string(args, "request_id");
    let fingerprint = start_fingerprint(args);
    let mut requests = session.start_requests.lock().await;
    if session.closed() {
        return Err(CLOSED);
    }
    if !request_id.is_empty() {
        if let Some(record) = requests.get(&request_id) {
            if record.fingerprint != fingerprint {
                return Err(OpError::Local(
                    "process start request id was reused with different arguments",
                ));
            }
            let process = session
                .processes
                .lock()
                .expect("processes")
                .running
                .get(&record.process_id)
                .cloned();
            // The start was sent and its stream is gone: only the Host knows.
            let process = process.ok_or(OpError::Local("process start outcome is unknown"))?;
            let state = process.state.lock().expect("process state").state;
            return Ok(json!({"process_id": record.process_id, "state": state}));
        }
        if requests.len() >= MAX_START_REQUESTS {
            return Err(OpError::Local("process start idempotency history is full"));
        }
    }

    let argv = json::string_list(args, "command");
    if argv.is_empty() {
        return Err(OpError::Local("process command is required"));
    }
    let mut process_id = json::string(args, "process_id");
    if process_id.is_empty() {
        process_id = if request_id.is_empty() {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default();
            format!("process-{}", now.as_nanos())
        } else {
            format!("process-request-{request_id}")
        };
    }
    let exists = |process_id: &str| {
        session
            .processes
            .lock()
            .expect("processes")
            .running
            .contains_key(process_id)
    };
    if !request_id.is_empty() && exists(&process_id) {
        return Err(OpError::Local("process id already exists"));
    }
    if !json::string(args, "container_id").is_empty() {
        return Err(OpError::Local(
            "process container target is controller-owned",
        ));
    }
    let execution = format!("process:{process_id}");
    let forwarded =
        prepare_execution(runtime, args, execution, host::ExecutionKind::Process).await?;
    // The process outlives this operation: its stream has no deadline.
    let ClientCall { mut tx, rx } = session.call("Exec", None).await?;
    {
        let mut processes = session.processes.lock().expect("processes");
        if session.closed() {
            return Err(CLOSED);
        }
        prune_processes(&mut processes);
        if processes.running.len() + processes.starting >= MAX_PROCESSES {
            return Err(OpError::Local("runtime process limit reached"));
        }
        processes.starting += 1;
    }
    let slot = StartSlot(&session.processes);

    let mut start = exec_start(&forwarded, argv, host::ExecutionKind::Process as i32);
    start.timeout_ms = 0;
    start.request_id = json::string(args, "request_id");
    if start.request_id.is_empty() {
        start.request_id = process_id.clone();
    }
    if !request_id.is_empty() {
        // Reserved only once every known failure before the send has passed. A
        // failed send stays fenced: the Host may have accepted the start.
        let record = StartRecord {
            process_id: process_id.clone(),
            fingerprint,
        };
        requests.insert(request_id.clone(), record);
    }
    tx.send(&exec_request(host::exec_request::Event::Start(start)))
        .await?;

    let process = Arc::new(RuntimeProcess {
        created_at: Instant::now(),
        sender: tokio::sync::Mutex::new(tx),
        state: Mutex::new(ProcessState {
            stdout: Vec::new(),
            stderr: Vec::new(),
            state: "running",
            exit_code: None,
            oom_killed: false,
            memory_peak_bytes: None,
            version: 0,
            last_tailed_version: 0,
        }),
        notify: tokio::sync::Notify::new(),
        receiver: Mutex::new(None),
    });
    let receiver = tokio::spawn(receive_process(process.clone(), rx)).abort_handle();
    drop(slot);
    let mut processes = session.processes.lock().expect("processes");
    let refused = if session.closed() {
        Some(CLOSED)
    } else if processes.running.contains_key(&process_id) {
        Some(OpError::Local("process id already exists"))
    } else {
        prune_processes(&mut processes);
        (processes.running.len() >= MAX_PROCESSES)
            .then_some(OpError::Local("runtime process limit reached"))
    };
    if let Some(refused) = refused {
        receiver.abort();
        return Err(refused);
    }
    *process.receiver.lock().expect("receiver") = Some(receiver);
    processes.running.insert(process_id.clone(), process);
    Ok(json!({"process_id": process_id, "state": "running"}))
}

async fn receive_process(process: Arc<RuntimeProcess>, mut rx: ClientReceiver) {
    loop {
        let response = rx.message::<host::ExecResponse>().await;
        let (changed, finished) = {
            let mut state = process.state.lock().expect("process state");
            match response {
                Ok(Some(response)) => match response.event {
                    Some(host::exec_response::Event::Stdout(bytes)) if !bytes.is_empty() => {
                        append_bounded(&mut state.stdout, &bytes);
                        state.version = state.version.wrapping_add(1);
                        (true, false)
                    }
                    Some(host::exec_response::Event::Stderr(bytes)) if !bytes.is_empty() => {
                        append_bounded(&mut state.stderr, &bytes);
                        state.version = state.version.wrapping_add(1);
                        (true, false)
                    }
                    Some(host::exec_response::Event::ExitCode(code)) => {
                        state.exit_code = Some(code);
                        state.oom_killed = response.oom_killed;
                        state.memory_peak_bytes = response.memory_peak_bytes;
                        state.state = "exited";
                        state.version = state.version.wrapping_add(1);
                        (true, false)
                    }
                    _ => (false, false),
                },
                // The stream ended without an exit code: only the Host knows the outcome.
                Ok(None) | Err(_) => {
                    let updated = if state.state != "exited" {
                        state.state = "unknown";
                        state.version = state.version.wrapping_add(1);
                        true
                    } else {
                        false
                    };
                    (updated, true)
                }
            }
        };
        if changed {
            process.notify.notify_waiters();
        }
        if finished {
            return;
        }
    }
}

/// Keeps the newest `OUTPUT_BOUND` bytes.
fn append_bounded(existing: &mut Vec<u8>, value: &[u8]) {
    if value.len() >= OUTPUT_BOUND {
        *existing = value[value.len() - OUTPUT_BOUND..].to_vec();
        return;
    }
    let excess = (existing.len() + value.len()).saturating_sub(OUTPUT_BOUND);
    existing.drain(..excess);
    existing.extend_from_slice(value);
}

/// At the bound, forgets the oldest process that is no longer running.
fn prune_processes(processes: &mut Processes) {
    if processes.running.len() < MAX_PROCESSES {
        return;
    }
    let oldest = processes
        .running
        .iter()
        .filter(|(_, process)| process.state.lock().expect("process state").state != "running")
        .min_by_key(|(_, process)| process.created_at)
        .map(|(process_id, _)| process_id.clone());
    if let Some(oldest) = oldest {
        processes.running.remove(&oldest);
    }
}

fn list_processes(session: &RuntimeSession) -> Value {
    let processes = session.processes.lock().expect("processes");
    let mut ids: Vec<&String> = processes.running.keys().collect();
    ids.sort();
    let items: Vec<Value> = ids
        .into_iter()
        .map(|process_id| {
            let state = processes.running[process_id]
                .state
                .lock()
                .expect("process state");
            let mut item = json!({"process_id": process_id, "state": state.state});
            if let Some(exit_code) = state.exit_code {
                item["exit_code"] = json!(exit_code);
            }
            if state.oom_killed {
                item["oom_killed"] = json!(true);
                if let Some(peak) = state.memory_peak_bytes {
                    item["memory_peak_bytes"] = json!(peak);
                }
            }
            item
        })
        .collect();
    json!({"processes": items})
}

fn find_process(session: &RuntimeSession, args: &Args) -> Result<Arc<RuntimeProcess>, OpError> {
    let process_id = json::string(args, "process_id");
    if process_id.is_empty() {
        return Err(OpError::Local("process_id is required"));
    }
    session
        .processes
        .lock()
        .expect("processes")
        .running
        .get(&process_id)
        .cloned()
        .ok_or(OpError::Local("process not found"))
}

fn snapshot_state(state: &ProcessState) -> Value {
    let mut result = json!({
        "stdout_base64": STANDARD.encode(&state.stdout),
        "stderr_base64": STANDARD.encode(&state.stderr),
        "state": state.state,
    });
    if let Some(exit_code) = state.exit_code {
        result["exit_code"] = json!(exit_code);
    }
    if state.oom_killed {
        result["oom_killed"] = json!(true);
        if let Some(peak) = state.memory_peak_bytes {
            result["memory_peak_bytes"] = json!(peak);
        }
    }
    result
}

fn snapshot(process: &RuntimeProcess) -> Value {
    let state = process.state.lock().expect("process state");
    snapshot_state(&state)
}

fn active_process_state(state: &str) -> bool {
    matches!(state, "running" | "stopping")
}

async fn tail_process(session: &RuntimeSession, args: &Args) -> Result<Value, OpError> {
    let process = find_process(session, args)?;
    let wait_ms = json::uint64(args, "wait_ms", 0).min(MAX_TAIL_WAIT_MS);
    if wait_ms == 0 {
        let mut state = process.state.lock().expect("process state");
        state.last_tailed_version = state.version;
        return Ok(snapshot_state(&state));
    }

    let deadline = Instant::now() + Duration::from_millis(wait_ms);
    let initial_version = {
        let mut state = process.state.lock().expect("process state");
        if state.version != state.last_tailed_version || !active_process_state(state.state) {
            state.last_tailed_version = state.version;
            return Ok(snapshot_state(&state));
        }
        state.version
    };

    loop {
        let notified = process.notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();

        {
            let mut state = process.state.lock().expect("process state");
            if state.version != initial_version || !active_process_state(state.state) {
                state.last_tailed_version = state.version;
                return Ok(snapshot_state(&state));
            }
        }

        if tokio::time::timeout_at(deadline, notified).await.is_err() {
            let mut state = process.state.lock().expect("process state");
            state.last_tailed_version = state.version;
            return Ok(snapshot_state(&state));
        }
    }
}

fn running(process: &RuntimeProcess) -> bool {
    process.state.lock().expect("process state").state == "running"
}

async fn write_process(session: &RuntimeSession, args: &Args) -> Result<Value, OpError> {
    let process = find_process(session, args)?;
    let data = decode_base64(args, "data_base64")
        .filter(|data| data.len() <= MEBIBYTE)
        .ok_or(OpError::Local("process input is invalid or too large"))?;
    let written = data.len();
    let mut sender = process.sender.lock().await;
    if !running(&process) {
        return Err(OpError::Local("process is not running"));
    }
    sender
        .send(&exec_request(host::exec_request::Event::Stdin(data)))
        .await?;
    Ok(json!({"written_bytes": written}))
}

async fn stop_process(session: &RuntimeSession, args: &Args) -> Result<Value, OpError> {
    let process = find_process(session, args)?;
    let signal = match json::string(args, "signal").to_uppercase().as_str() {
        "KILL" => host::ProcessSignal::Kill,
        "INT" => host::ProcessSignal::Int,
        "" | "TERM" => host::ProcessSignal::Term,
        _ => return Err(OpError::Local("unsupported process signal")),
    };
    let mut sender = process.sender.lock().await;
    if running(&process) {
        sender
            .send(&exec_request(host::exec_request::Event::Signal(
                signal as i32,
            )))
            .await?;
        let mut state = process.state.lock().expect("process state");
        if state.state == "running" {
            state.state = "stopping";
        }
    }
    drop(sender);
    Ok(snapshot(&process))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_output_keeps_its_newest_bytes() {
        let mut output = vec![1u8; OUTPUT_BOUND - 2];
        append_bounded(&mut output, &[2, 3, 4, 5]);
        assert_eq!(output.len(), OUTPUT_BOUND);
        assert_eq!(output[..2], [1, 1]);
        assert_eq!(output[OUTPUT_BOUND - 4..], [2, 3, 4, 5]);
        let mut replaced = vec![9u8; 10];
        let mut large = vec![7u8; OUTPUT_BOUND + 5];
        large[4] = 0;
        append_bounded(&mut replaced, &large);
        assert_eq!(replaced.len(), OUTPUT_BOUND);
        assert!(replaced.iter().all(|byte| *byte == 7));
    }

    #[test]
    fn a_start_fingerprint_ignores_only_its_identities() {
        let args = |value: Value| value.as_object().cloned().unwrap();
        let first =
            args(json!({"request_id": "a", "process_id": "p", "command": ["sh"], "env": ["A=1"]}));
        let retry = args(json!({"env": ["A=1"], "command": ["sh"], "request_id": "b"}));
        let other = args(json!({"request_id": "a", "command": ["sh"], "env": ["A=2"]}));
        assert_eq!(start_fingerprint(&first), start_fingerprint(&retry));
        assert_ne!(start_fingerprint(&first), start_fingerprint(&other));
    }

    #[test]
    fn resolve_exec_timeout_ms_applies_default_and_clamps() {
        let args = |value: Value| value.as_object().cloned().unwrap();
        assert_eq!(resolve_exec_timeout_ms(&args(json!({}))), 60_000);
        assert_eq!(
            resolve_exec_timeout_ms(&args(json!({"timeout_ms": 0}))),
            60_000
        );
        assert_eq!(
            resolve_exec_timeout_ms(&args(json!({"timeout_ms": 200}))),
            1_000
        );
        assert_eq!(
            resolve_exec_timeout_ms(&args(json!({"timeout_ms": 180_000}))),
            180_000
        );
        assert_eq!(
            resolve_exec_timeout_ms(&args(json!({"timeout_ms": 900_000}))),
            300_000
        );
    }

    #[test]
    fn every_operation_salix_names_is_served() {
        for operation in [
            "compute.exec",
            "process.start",
            "process.list",
            "process.write",
            "process.tail",
            "process.stop",
            "compute.workspace.stat",
            "compute.workspace.list",
            "compute.workspace.read",
            "compute.workspace.write",
            "compute.build.run",
            "compute.image.list",
            "compute.image.delete",
            "compute.volume.create",
            "compute.volume.get",
            "compute.volume.list",
            "compute.volume.delete",
            "compute.container.create",
            "compute.container.start",
            "compute.container.stop",
            "compute.container.get",
            "compute.container.list",
            "compute.container.delete",
            "compute.container.logs",
            "compute.container.exec",
            "compute.execution.acquire",
            "compute.execution.release",
            "compute.execution.list",
            "compute.container.quiesce",
            "compute.forward.tcp",
            "compute.service.export",
            "compute.service.import",
            "compute.route.revoke",
        ] {
            assert!(is_typed_operation(operation), "{operation}");
        }
        assert!(!is_typed_operation("environment_get"));
        assert!(!is_typed_operation("compute.image.import"));
    }
}
