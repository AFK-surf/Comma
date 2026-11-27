//! The worker's private Unix socket, for the Salix node that owns it. One
//! connection carries one request, as one `{:packet, 4}` JSON frame:
//!
//! * `session_call` runs a typed runtime operation and answers
//!   `{"status": S, "body": …}`, the status and body the former gateway's
//!   internal HTTP API answered;
//! * `iroh_tunnel` answers `{"type": "ready"}` and then carries the tunnel's
//!   bytes on the same connection.

use crate::{
    control::{read_packet, write_packet},
    gateway::Gateway,
    image_import::{self, ImportError},
    iroh_tunnel::{TunnelError, Tunnels},
    operations,
    runtime_error::runtime_error,
    session::SessionKey,
    status::Code,
};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::AsyncReadExt,
    net::{UnixListener, UnixStream, unix::OwnedWriteHalf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

pub struct Local {
    pub gateway: Arc<Gateway>,
    pub tunnels: Tunnels,
    pub token: String,
}

pub async fn serve(listener: UnixListener, local: Arc<Local>, shutdown: CancellationToken) {
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                if let Ok((stream, _)) = accepted {
                    tokio::spawn(handle(local.clone(), stream));
                }
            }
            _ = shutdown.cancelled() => return,
        }
    }
}

fn token_matches(expected: &str, presented: &str) -> bool {
    let (expected, presented) = (expected.as_bytes(), presented.as_bytes());
    expected.len() == presented.len()
        && expected
            .iter()
            .zip(presented)
            .fold(0u8, |difference, (left, right)| difference | (left ^ right))
            == 0
}

async fn reply<W: tokio::io::AsyncWrite + Unpin>(writer: &mut W, status: u16, body: Value) {
    let frame = json!({"status": status, "body": body});
    let _ = write_packet(writer, frame.to_string().as_bytes()).await;
}

async fn handle(local: Arc<Local>, mut stream: UnixStream) {
    let request = match tokio::time::timeout(REQUEST_TIMEOUT, read_packet(&mut stream)).await {
        Ok(Ok(Some(request))) => request,
        _ => return,
    };
    let Ok(request) = serde_json::from_slice::<Value>(&request) else {
        return reply(&mut stream, 400, json!({"error": "invalid_request"})).await;
    };
    if !token_matches(&local.token, request["token"].as_str().unwrap_or_default()) {
        return reply(&mut stream, 401, json!({"error": "unauthorized"})).await;
    }
    match request["op"].as_str() {
        Some("session_call") => session_call(&local, stream, &request).await,
        Some("iroh_tunnel") => iroh_tunnel(&local, stream, &request).await,
        _ => reply(&mut stream, 404, Value::Null).await,
    }
}

fn uint(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| value.as_str()?.parse().ok())
}

fn session_key(session: &Value) -> Option<SessionKey> {
    Some(SessionKey {
        registration_id: session["registration_id"].as_str()?.to_owned(),
        allocation_id: session["allocation_id"].as_str()?.to_owned(),
        allocation_generation: uint(&session["allocation_generation"])?,
        connection_epoch: uint(&session["connection_epoch"])?,
    })
}

async fn session_call(local: &Local, stream: UnixStream, request: &Value) {
    let (mut read, mut write) = stream.into_split();
    // The caller closing its end withdraws the request.
    let caller_left = async {
        let mut byte = [0u8; 1];
        let _ = read.read(&mut byte).await;
    };
    let operation = request["operation"].as_str().unwrap_or_default();
    if operation == "compute.image.import" {
        return image_import(local, &mut write, request, caller_left).await;
    }
    if !operations::is_typed_operation(operation) {
        return reply(&mut write, 404, Value::Null).await;
    }
    let Some(args) = request["args"].as_object() else {
        return reply(&mut write, 400, Value::Null).await;
    };
    let Some(key) = session_key(&request["session"]) else {
        return reply(&mut write, 400, Value::Null).await;
    };
    let Some(session) = local.gateway.session(&key) else {
        return reply(&mut write, 404, Value::Null).await;
    };
    let result = tokio::select! {
        result = operations::execute(&session, operation, args) => result,
        _ = caller_left => return,
    };
    match result {
        Ok(result) => reply(&mut write, 200, result).await,
        Err(error) => {
            let (status, body) = runtime_error(operation, error);
            reply(&mut write, status, body).await
        }
    }
}

async fn image_import(
    local: &Local,
    write: &mut OwnedWriteHalf,
    request: &Value,
    caller_left: impl Future<Output = ()>,
) {
    let started = Instant::now();
    let mut archive_size = 0u64;
    let outcome = 'import: {
        let stale = |message| ImportError::new("stale_session", "runtime", message);
        let session = session_key(&request["session"])
            .and_then(|key| Some((local.gateway.session(&key)?, key)));
        let Some((session, key)) = session else {
            let error = stale("Image import session is unavailable.");
            reply(write, 404, error.to_json()).await;
            break 'import "failure";
        };
        let metadata = request["headers"]
            .as_object()
            .and_then(image_import::parse_metadata);
        let Some(metadata) = metadata else {
            let error = ImportError::new(
                "invalid_argument",
                "image",
                "Image import request was rejected.",
            );
            reply(write, 400, error.to_json()).await;
            break 'import "failure";
        };
        archive_size = metadata.archive_size;
        let imported = tokio::select! {
            imported = image_import::import_image(&session, &metadata) => imported,
            _ = caller_left => break 'import "canceled",
        };
        let image = match imported {
            Ok(image) => image,
            Err(status) => {
                let (http_status, error) = image_import::canonical_error(&status);
                reply(write, http_status, error.to_json()).await;
                let interrupted = matches!(status.code, Code::Canceled | Code::DeadlineExceeded);
                break 'import if interrupted { "canceled" } else { "failure" };
            }
        };
        if !local.gateway.is_current_session(&key, &session) {
            reply(write, 409, stale("Image import session changed.").to_json()).await;
            break 'import "stale";
        }
        if !image_import::validate_imported(&image, &metadata) {
            let error = ImportError::new(
                "image_import_failed",
                "image",
                "Imported image validation failed.",
            );
            reply(write, 502, error.to_json()).await;
            break 'import "failure";
        }
        let body = json!({
            "reference": image.reference, "digest": image.digest,
            "platform": metadata.platform, "logical_bytes": image.logical_bytes,
            "generation_id": image.generation_id,
        });
        reply(write, 200, body).await;
        "success"
    };
    local.gateway.control.event(json!({
        "event": "image_import", "outcome": outcome,
        "bytes": if outcome == "success" { archive_size } else { 0 },
        "duration_ms": started.elapsed().as_millis() as u64,
    }));
}

async fn iroh_tunnel(local: &Local, mut stream: UnixStream, request: &Value) {
    local.gateway.count("iroh_connect");
    match local.tunnels.dial(&request["endpoint_addr"]).await {
        Ok(tunnel) => {
            let ready = json!({"type": "ready"});
            if write_packet(&mut stream, ready.to_string().as_bytes())
                .await
                .is_ok()
            {
                tunnel.bridge(stream).await;
            }
        }
        Err(error) => {
            local.gateway.count("iroh_connect_failure");
            let (status, reason) = match error {
                TunnelError::InvalidAddress => (400, "invalid endpoint address"),
                TunnelError::CapacityExhausted => (503, "iroh capacity exhausted"),
                TunnelError::Unavailable => (503, "iroh unavailable"),
                TunnelError::ConnectFailed => (502, "iroh connect failed"),
            };
            reply(&mut stream, status, json!({"error": reason})).await;
        }
    }
}
