//! The finite error vocabulary of typed runtime operations. Only decisions the
//! Host owns cross this boundary: error text and resource names can hold local
//! paths or credentials and are never forwarded.

use crate::status::{Code, Status};
use serde_json::{Value, json};

/// A failure of a typed operation: a Host status, or a refusal made here.
#[derive(Debug)]
pub enum OpError {
    Status(Status),
    Local(&'static str),
}

impl From<Status> for OpError {
    fn from(status: Status) -> Self {
        Self::Status(status)
    }
}

impl OpError {
    fn status(self) -> Status {
        match self {
            Self::Status(status) => status,
            Self::Local(message) => Status::new(Code::Unknown, message),
        }
    }
}

/// The HTTP status the former gateway answered for a Host status code.
pub fn http_status(code: Code) -> u16 {
    match code {
        Code::InvalidArgument => 400,
        Code::Unauthenticated => 401,
        Code::PermissionDenied => 403,
        Code::NotFound => 404,
        Code::AlreadyExists | Code::Aborted | Code::FailedPrecondition => 409,
        Code::ResourceExhausted => 429,
        Code::Canceled => 408,
        Code::DeadlineExceeded => 504,
        Code::Unavailable => 503,
        _ => 502,
    }
}

pub fn runtime_error(operation: &str, error: OpError) -> (u16, Value) {
    let stage = match operation {
        "compute.container.start" => "container_start",
        "compute.execution.acquire" => "execution_acquire",
        "compute.container.quiesce" => "container_quiesce",
        "compute.container.stop" => "container_stop",
        _ => "runtime",
    };
    let status = error.status();
    let mut code = match status.code {
        Code::InvalidArgument => "invalid_argument",
        Code::PermissionDenied => "permission_denied",
        Code::NotFound => "not_found",
        Code::AlreadyExists => "already_exists",
        Code::FailedPrecondition => "failed_precondition",
        Code::ResourceExhausted => "resource_exhausted",
        Code::DeadlineExceeded => "deadline_exceeded",
        Code::Canceled => "canceled",
        Code::Aborted => "aborted",
        Code::Unauthenticated => "unauthenticated",
        Code::Unavailable => "unavailable",
        _ => "runtime_failed",
    };
    if stage != "runtime" {
        for info in status.error_infos() {
            if info.domain != "agent-vmm" {
                continue;
            }
            code = match (status.code, info.reason.as_str()) {
                (Code::Aborted, "STALE_CONTAINER_INSTANCE") => "stale_container_instance",
                (Code::ResourceExhausted, "WORKLOAD_EXECUTION_BUSY") => "workload_execution_busy",
                (Code::Aborted, "STALE_EXECUTION") => "stale_execution",
                (Code::FailedPrecondition, "LIFECYCLE_CONFLICT") => "lifecycle_conflict",
                (Code::FailedPrecondition, "WORKLOAD_STOP_UNRESOLVED") => {
                    "workload_stop_unresolved"
                }
                _ => code,
            };
        }
    }
    let body = json!({
        "code": code, "stage": stage, "resource": "runtime",
        "message": "Runtime operation was rejected.",
    });
    (http_status(status.code), body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn host(code: Code, domain: &str, reason: &str) -> OpError {
        OpError::Status(Status::with_error_info(
            code,
            "/var/lib/agent-vmm/secret/path leaked",
            domain,
            reason,
            HashMap::new(),
        ))
    }

    #[test]
    fn host_decisions_keep_their_finite_code_and_never_their_text() {
        let (status, body) = runtime_error(
            "compute.container.start",
            host(Code::Aborted, "agent-vmm", "STALE_CONTAINER_INSTANCE"),
        );
        assert_eq!(status, 409);
        assert_eq!(
            body,
            json!({"code": "stale_container_instance", "stage": "container_start",
                   "resource": "runtime", "message": "Runtime operation was rejected."})
        );
        let busy = host(
            Code::ResourceExhausted,
            "agent-vmm",
            "WORKLOAD_EXECUTION_BUSY",
        );
        assert_eq!(
            runtime_error("compute.execution.acquire", busy).1["code"],
            "workload_execution_busy"
        );
        let unresolved = host(
            Code::FailedPrecondition,
            "agent-vmm",
            "WORKLOAD_STOP_UNRESOLVED",
        );
        assert_eq!(
            runtime_error("compute.container.stop", unresolved).1["code"],
            "workload_stop_unresolved"
        );
    }

    #[test]
    fn a_reason_counts_only_from_the_host_domain_code_and_stage() {
        // Another domain, another status code, or an operation without a stage of its own.
        let foreign = host(Code::Aborted, "other", "STALE_CONTAINER_INSTANCE");
        assert_eq!(
            runtime_error("compute.container.start", foreign).1["code"],
            "aborted"
        );
        let mismatched = host(
            Code::FailedPrecondition,
            "agent-vmm",
            "STALE_CONTAINER_INSTANCE",
        );
        assert_eq!(
            runtime_error("compute.container.start", mismatched).1["code"],
            "failed_precondition"
        );
        let unstaged = host(Code::Aborted, "agent-vmm", "STALE_EXECUTION");
        let (status, body) = runtime_error("compute.exec", unstaged);
        assert_eq!(
            (status, body["code"].as_str(), body["stage"].as_str()),
            (409, Some("aborted"), Some("runtime"))
        );
    }

    #[test]
    fn local_refusals_and_unlisted_codes_are_runtime_failures() {
        let (status, body) = runtime_error("process.tail", OpError::Local("process not found"));
        assert_eq!(
            (status, body["code"].as_str()),
            (502, Some("runtime_failed"))
        );
        let internal = OpError::Status(Status::new(Code::Internal, "boom"));
        assert_eq!(
            runtime_error("compute.exec", internal),
            (
                502,
                json!({
            "code": "runtime_failed", "stage": "runtime", "resource": "runtime",
            "message": "Runtime operation was rejected."})
            )
        );
        let deadline = OpError::Status(Status::new(Code::DeadlineExceeded, ""));
        assert_eq!(runtime_error("compute.exec", deadline).0, 504);
    }
}
