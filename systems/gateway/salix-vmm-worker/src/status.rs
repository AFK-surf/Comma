//! The terminal status of one `agent-vmm/rpc/1` call (`google.rpc.Code`).

use crate::pb::google::rpc;
use base64::{Engine, engine::general_purpose::STANDARD};
use prost::Message;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Code {
    Ok = 0,
    Canceled = 1,
    Unknown = 2,
    InvalidArgument = 3,
    DeadlineExceeded = 4,
    NotFound = 5,
    AlreadyExists = 6,
    PermissionDenied = 7,
    ResourceExhausted = 8,
    FailedPrecondition = 9,
    Aborted = 10,
    OutOfRange = 11,
    Unimplemented = 12,
    Internal = 13,
    Unavailable = 14,
    DataLoss = 15,
    Unauthenticated = 16,
}

impl Code {
    pub fn from_i32(value: i32) -> Self {
        match value {
            0 => Self::Ok,
            1 => Self::Canceled,
            3 => Self::InvalidArgument,
            4 => Self::DeadlineExceeded,
            5 => Self::NotFound,
            6 => Self::AlreadyExists,
            7 => Self::PermissionDenied,
            8 => Self::ResourceExhausted,
            9 => Self::FailedPrecondition,
            10 => Self::Aborted,
            11 => Self::OutOfRange,
            12 => Self::Unimplemented,
            13 => Self::Internal,
            14 => Self::Unavailable,
            15 => Self::DataLoss,
            16 => Self::Unauthenticated,
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub code: Code,
    pub message: String,
    /// An encoded `google.rpc.Status`, or empty.
    pub details: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
struct WireStatus {
    code: i32,
    #[serde(default)]
    message: String,
    #[serde(default)]
    details_b64: String,
}

impl Status {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: Vec::new(),
        }
    }

    pub fn ok() -> Self {
        Self::new(Code::Ok, "")
    }

    pub fn is_ok(&self) -> bool {
        self.code == Code::Ok
    }

    pub fn with_error_info(
        code: Code,
        message: impl Into<String>,
        domain: &str,
        reason: &str,
        metadata: HashMap<String, String>,
    ) -> Self {
        let message = message.into();
        let info = rpc::ErrorInfo {
            reason: reason.into(),
            domain: domain.into(),
            metadata,
        };
        let details = rpc::Status {
            code: code as i32,
            message: message.clone(),
            details: vec![prost_types::Any {
                type_url: "type.googleapis.com/google.rpc.ErrorInfo".into(),
                value: info.encode_to_vec(),
            }],
        };
        Self {
            code,
            message,
            details: details.encode_to_vec(),
        }
    }

    /// Every `google.rpc.ErrorInfo` the status carries.
    pub fn error_infos(&self) -> Vec<rpc::ErrorInfo> {
        let Ok(status) = rpc::Status::decode(self.details.as_slice()) else {
            return Vec::new();
        };
        status
            .details
            .iter()
            .filter(|detail| detail.type_url.rsplit('/').next() == Some("google.rpc.ErrorInfo"))
            .filter_map(|detail| rpc::ErrorInfo::decode(detail.value.as_slice()).ok())
            .collect()
    }

    pub fn encode(&self) -> Vec<u8> {
        let wire = WireStatus {
            code: self.code as i32,
            message: self.message.clone(),
            details_b64: STANDARD.encode(&self.details),
        };
        serde_json::to_vec(&wire).expect("a status is JSON")
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let wire: WireStatus = serde_json::from_slice(bytes).ok()?;
        Some(Self {
            code: Code::from_i32(wire.code),
            message: wire.message,
            details: STANDARD.decode(wire.details_b64).ok()?,
        })
    }
}
