//! `PersonalMeshRegistryService`: Salix owns the registry. The worker
//! authenticates the Host and carries the typed request and signed response.

use crate::{
    connect::{authentication_control_error, remote_identity},
    control::CALL_TIMEOUT,
    gateway::Gateway,
    pb::{self, trust},
    rpc::ServerCall,
    status::{Code, Status},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use prost::{Message, Name};
use serde_json::{Value, json};
use std::sync::Arc;

const SERVICE: &str = "/agentvmm.trust.v1.PersonalMeshRegistryService/";

struct Method {
    op: &'static str,
    /// A change is refused while the worker drains; a read is not.
    mutates: bool,
    request: fn(&[u8]) -> Option<Value>,
    response: fn(Vec<u8>) -> Option<Vec<u8>>,
}

fn request<M: Message + Name + Default>(bytes: &[u8]) -> Option<Value> {
    pb::to_json(&M::decode(bytes).ok()?).ok()
}

/// Salix answers these with the signed response's protobuf bytes.
fn binary<M: Message + Default>(bytes: Vec<u8>) -> Option<Vec<u8>> {
    M::decode(bytes.as_slice()).ok()?;
    Some(bytes)
}

/// Salix answers the endpoint list as canonical protobuf JSON.
fn list_endpoints(bytes: Vec<u8>) -> Option<Vec<u8>> {
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    let response: trust::ListEndpointsResponse = pb::from_json(&value).ok()?;
    Some(response.encode_to_vec())
}

fn method(name: &str) -> Option<Method> {
    Some(match name {
        "CreateMesh" => Method {
            op: "registry_create",
            mutates: true,
            request: request::<trust::CreateMeshRequest>,
            response: binary::<trust::CreateMeshResponse>,
        },
        "CommitJoin" => Method {
            op: "registry_join",
            mutates: true,
            request: request::<trust::CommitJoinRequest>,
            response: binary::<trust::CommitJoinResponse>,
        },
        "CommitRevoke" => Method {
            op: "registry_revoke",
            mutates: true,
            request: request::<trust::CommitRevokeRequest>,
            response: binary::<trust::CommitRevokeResponse>,
        },
        "GetSnapshot" => Method {
            op: "registry_snapshot",
            mutates: false,
            request: request::<trust::GetSnapshotRequest>,
            response: binary::<trust::GetSnapshotResponse>,
        },
        "PublishEndpoint" => Method {
            op: "registry_endpoint",
            mutates: true,
            request: request::<trust::PublishEndpointRequest>,
            response: binary::<trust::PublishEndpointResponse>,
        },
        "ListEndpoints" => Method {
            op: "registry_endpoints",
            mutates: false,
            request: request::<trust::ListEndpointsRequest>,
            response: list_endpoints,
        },
        _ => return None,
    })
}

/// Whether `path` names a registry method this worker serves.
pub fn serves(path: &str) -> bool {
    path.strip_prefix(SERVICE).and_then(method).is_some()
}

pub async fn serve(gateway: Arc<Gateway>, mut call: ServerCall) {
    let result = unary(&gateway, &mut call).await;
    let status = match result {
        Ok(response) => match call.tx.message(&response).await {
            Ok(()) => Status::ok(),
            Err(_) => return,
        },
        Err(status) => status,
    };
    let _ = call.tx.finish(&status).await;
}

async fn unary(gateway: &Gateway, call: &mut ServerCall) -> Result<Vec<u8>, Status> {
    let method = call
        .header
        .method
        .strip_prefix(SERVICE)
        .and_then(method)
        .ok_or_else(|| Status::new(Code::Unimplemented, "unknown method"))?;
    let (registration_id, credential) = remote_identity(&call.header)?;
    gateway
        .authenticate(&registration_id, &credential)
        .await
        .map_err(|error| authentication_control_error(&error))?;
    if method.mutates && gateway.draining() {
        return Err(Status::new(
            Code::Unavailable,
            "gateway is draining or unavailable",
        ));
    }
    let message = call
        .rx
        .message()
        .await?
        .ok_or_else(|| Status::new(Code::InvalidArgument, "request message required"))?;
    let request = (method.request)(&message)
        .ok_or_else(|| Status::new(Code::InvalidArgument, "request message is invalid"))?;
    let body = json!({"request_json_b64": STANDARD.encode(request.to_string())});
    let answer = gateway
        .call(method.op, body, CALL_TIMEOUT)
        .await
        .map_err(|error| match error.status() {
            Some(_) => Status::new(Code::Unknown, error.to_string()),
            None => Status::new(Code::Unavailable, "registry control unavailable"),
        })?
        .unwrap_or(Value::Null);
    answer["response_b64"]
        .as_str()
        .and_then(|encoded| STANDARD.decode(encoded).ok())
        .and_then(method.response)
        .ok_or_else(|| Status::new(Code::Internal, "registry response is invalid"))
}
