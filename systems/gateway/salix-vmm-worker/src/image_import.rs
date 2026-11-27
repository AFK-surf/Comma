//! `compute.image.import`: the Host fetches one content-addressed OCI archive
//! itself. Only its committed identity crosses here, never archive bytes.

use crate::{
    pb::host,
    rpc::ClientCall,
    runtime_error::http_status,
    session::RuntimeSession,
    status::{Code, Status},
};
use serde_json::{Map, Value, json};
use std::time::Duration;
use tokio::time::Instant;

const MAX_IMAGE_IMPORT_BYTES: u64 = 8 << 30;
pub const IMAGE_IMPORT_TIMEOUT: Duration = Duration::from_secs(750);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportMetadata {
    pub request_id: String,
    pub reference: String,
    pub archive_sha256: Vec<u8>,
    pub manifest_digest: String,
    pub platform: String,
    pub archive_size: u64,
    pub archive_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportError {
    pub code: &'static str,
    pub stage: &'static str,
    pub resource: &'static str,
    pub message: &'static str,
    pub available_bytes: Option<u64>,
    pub required_bytes: Option<u64>,
}

impl ImportError {
    pub const fn new(code: &'static str, resource: &'static str, message: &'static str) -> Self {
        Self {
            code,
            stage: "image_import",
            resource,
            message,
            available_bytes: None,
            required_bytes: None,
        }
    }

    pub fn to_json(&self) -> Value {
        let mut value = json!({
            "code": self.code, "stage": self.stage, "resource": self.resource,
            "message": self.message,
        });
        if let Some(bytes) = self.available_bytes {
            value["available_bytes"] = json!(bytes);
        }
        if let Some(bytes) = self.required_bytes {
            value["required_bytes"] = json!(bytes);
        }
        value
    }
}

fn is_request_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=63).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
}

fn is_lower_hex(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn decode_hex(value: &str) -> Option<Vec<u8>> {
    if !value.len().is_multiple_of(2) || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    (0..value.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&value[index..index + 2], 16).ok())
        .collect()
}

/// An `https` URL with a host and without credentials, query or fragment.
fn is_archive_url(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("https://") else {
        return false;
    };
    let authority = rest.split('/').next().unwrap_or_default();
    !authority.is_empty()
        && !authority.contains('@')
        && !value.contains(['?', '#'])
        && !value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
}

/// Reads the import's committed identity from the request's header fields.
pub fn parse_metadata(headers: &Map<String, Value>) -> Option<ImportMetadata> {
    let header = |name: &str| {
        headers
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or_default()
    };
    let request_id = header("x-comma-import-request-id");
    let reference = header("x-comma-image-reference");
    let manifest_digest = header("x-comma-manifest-digest");
    let platform = header("x-comma-platform");
    let archive_url = header("x-comma-archive-url");
    let archive_sha256 = header("x-comma-archive-sha256");
    let archive_size = header("x-comma-archive-size");
    let digest = manifest_digest.strip_prefix("sha256:")?;
    let archive_size = archive_size
        .parse::<u64>()
        .ok()
        .filter(|_| archive_size.bytes().all(|byte| byte.is_ascii_digit()))
        .filter(|size| (1..=MAX_IMAGE_IMPORT_BYTES).contains(size))?;
    let valid = is_request_id(request_id)
        && (1..=255).contains(&reference.len())
        && !reference.contains(['\r', '\n'])
        && digest.len() == 64
        && is_lower_hex(digest)
        && platform == "linux/arm64"
        && is_archive_url(archive_url)
        && archive_sha256.len() == 64;
    if !valid {
        return None;
    }
    Some(ImportMetadata {
        request_id: request_id.into(),
        reference: reference.into(),
        archive_sha256: decode_hex(archive_sha256)?,
        manifest_digest: manifest_digest.into(),
        platform: platform.into(),
        archive_size,
        archive_url: archive_url.into(),
    })
}

/// Asks the Host to import the archive and waits for the image it stored.
pub async fn import_image(
    session: &RuntimeSession,
    metadata: &ImportMetadata,
) -> Result<host::Image, Status> {
    let deadline = Instant::now() + IMAGE_IMPORT_TIMEOUT;
    let ClientCall { mut tx, mut rx } = session.call("ImportImage", Some(deadline)).await?;
    let header = host::ImportImageHeader {
        request_id: metadata.request_id.clone(),
        image_reference: metadata.reference.clone(),
        archive_sha256: metadata.archive_sha256.clone(),
        manifest_digest: metadata.manifest_digest.clone(),
        platform: metadata.platform.clone(),
        archive_size: metadata.archive_size,
        archive_url: metadata.archive_url.clone(),
    };
    let request = host::ImportImageRequest {
        payload: Some(host::import_image_request::Payload::Header(header)),
    };
    let sent = match tx.send(&request).await {
        Ok(()) => tx.close().await,
        Err(error) => Err(error),
    };
    if let Err(error) = sent {
        // The Host may have ended the call already: its status is the answer.
        return match rx.message::<host::ImportImageResponse>().await {
            Err(status) if status.code != Code::Unavailable => Err(status),
            _ => Err(error),
        };
    }
    let response = rx
        .message::<host::ImportImageResponse>()
        .await?
        .ok_or_else(|| Status::new(Code::Internal, "response message required"))?;
    if let Some(_extra) = rx.message::<host::ImportImageResponse>().await? {
        return Err(Status::new(Code::Internal, "unexpected response message"));
    }
    Ok(response.image.unwrap_or_default())
}

pub fn validate_imported(image: &host::Image, metadata: &ImportMetadata) -> bool {
    image.reference == metadata.reference
        && image.digest == metadata.manifest_digest
        && image.platforms.contains(&metadata.platform)
}

fn code_and_message(code: Code) -> (&'static str, &'static str) {
    match code {
        Code::InvalidArgument => ("invalid_argument", "Image import request was rejected."),
        Code::Unauthenticated => ("unauthenticated", "Image import authentication failed."),
        Code::PermissionDenied => ("permission_denied", "Image import is not authorized."),
        Code::DataLoss => ("data_loss", "Image import artifact is corrupted."),
        Code::NotFound => ("not_found", "Image import artifact was not found."),
        Code::AlreadyExists => (
            "already_exists",
            "Image import conflicts with existing state.",
        ),
        Code::Aborted => ("aborted", "Image import was aborted."),
        Code::FailedPrecondition => ("failed_precondition", "Image import precondition failed."),
        Code::ResourceExhausted => (
            "resource_exhausted",
            "Image import capacity is unavailable.",
        ),
        Code::Canceled => ("canceled", "Image import was canceled."),
        Code::DeadlineExceeded => ("deadline_exceeded", "Image import timed out."),
        Code::Unavailable => ("unavailable", "Image import transport is unavailable."),
        _ => ("image_import_failed", "Image import failed."),
    }
}

/// The bounded error Salix stores for a failed import. Capacity facts are kept
/// only when the Host names one of its two import resources at their stage.
pub fn canonical_error(status: &Status) -> (u16, ImportError) {
    let (code, message) = code_and_message(status.code);
    let mut result = ImportError::new(code, "runtime", message);
    for info in status.error_infos() {
        if status.code == Code::Unavailable
            && info.domain == "agent-vmm"
            && info.reason == "OPERATION_IN_PROGRESS"
        {
            return (
                http_status(status.code),
                ImportError::new(
                    "import_in_progress",
                    "runtime",
                    "Image import is in progress.",
                ),
            );
        }
        if status.code != Code::ResourceExhausted
            || info.domain != "agent-vmm"
            || info.reason != "RESOURCE_CAPACITY_EXHAUSTED"
        {
            continue;
        }
        let field = |key: &str| {
            info.metadata
                .get(key)
                .map(String::as_str)
                .unwrap_or_default()
        };
        let (resource, stage) = match (field("resource_dimension"), field("stage")) {
            ("storage_headroom", "import_admission" | "vm_capacity") => {
                ("storage_headroom", "import_admission")
            }
            ("import_slot", "import_slot") => ("import_slot", "import_slot"),
            _ => continue,
        };
        result.code = "resource_capacity_exhausted";
        result.resource = resource;
        result.stage = stage;
        result.available_bytes = field("available_bytes").parse().ok();
        result.required_bytes = field("required_bytes").parse().ok();
    }
    match result.resource {
        "storage_headroom" => result.message = "Guest storage headroom is unavailable.",
        "import_slot" => result.message = "Guest OCI import slot is occupied.",
        _ if result.code.starts_with("image_")
            || matches!(
                status.code,
                Code::InvalidArgument | Code::NotFound | Code::PermissionDenied | Code::DataLoss
            ) =>
        {
            result.resource = "image";
        }
        _ => {}
    }
    (http_status(status.code), result)
}

/// An import cut short here (the caller left or the bound passed) names no image.
pub fn interrupted_error(code: Code) -> (u16, ImportError) {
    let (code_name, message) = code_and_message(code);
    (
        http_status(code),
        ImportError::new(code_name, "runtime", message),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn headers() -> Map<String, Value> {
        json!({
            "x-comma-import-request-id": "import-1",
            "x-comma-image-reference": format!("comma.local/runtime/shell@sha256:{}", "a".repeat(64)),
            "x-comma-archive-size": "1024",
            "x-comma-archive-sha256": "b".repeat(64),
            "x-comma-archive-url": format!("https://cdn.example/runtime-bundles/sha256/{}.erofs.zst", "b".repeat(64)),
            "x-comma-manifest-digest": format!("sha256:{}", "a".repeat(64)),
            "x-comma-platform": "linux/arm64",
        })
        .as_object()
        .cloned()
        .unwrap()
    }

    #[test]
    fn metadata_names_one_committed_archive() {
        let metadata = parse_metadata(&headers()).unwrap();
        assert_eq!(metadata.archive_sha256, vec![0xbb; 32]);
        assert_eq!(metadata.archive_size, 1024);

        let mut legacy_oci = headers();
        legacy_oci.insert(
            "x-comma-archive-url".into(),
            json!(format!(
                "https://cdn.example/runtime-bundles/sha256/{}.oci.tar",
                "b".repeat(64)
            )),
        );
        assert!(parse_metadata(&legacy_oci).is_some());

        let rejected = |name: &str, value: &str| {
            let mut headers = headers();
            headers.insert(name.into(), json!(value));
            parse_metadata(&headers).is_none()
        };
        assert!(rejected("x-comma-import-request-id", "-leading"));
        assert!(rejected("x-comma-import-request-id", &"r".repeat(64)));
        assert!(rejected("x-comma-image-reference", "line\nbreak"));
        assert!(rejected(
            "x-comma-manifest-digest",
            &format!("sha256:{}", "A".repeat(64))
        ));
        assert!(rejected("x-comma-platform", "linux/amd64"));
        assert!(rejected("x-comma-archive-size", "0"));
        assert!(rejected("x-comma-archive-size", "8589934593"));
        assert!(rejected("x-comma-archive-size", "+5"));
        assert!(rejected("x-comma-archive-sha256", &"z".repeat(64)));
        for url in [
            "http://cdn.example/a",
            "https:///a",
            "https://user@cdn.example/a",
            "https://cdn.example/a?token=1",
            "https://cdn.example/a#part",
        ] {
            assert!(rejected("x-comma-archive-url", url), "{url}");
        }
    }

    fn capacity(code: Code, domain: &str, reason: &str, metadata: &[(&str, &str)]) -> Status {
        let metadata: HashMap<String, String> = metadata
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        Status::with_error_info(code, "/private/path", domain, reason, metadata)
    }

    #[test]
    fn capacity_errors_keep_their_resource_stage_and_bytes() {
        let headroom = capacity(
            Code::ResourceExhausted,
            "agent-vmm",
            "RESOURCE_CAPACITY_EXHAUSTED",
            &[
                ("resource_dimension", "storage_headroom"),
                ("stage", "import_admission"),
                ("available_bytes", "1024"),
                ("required_bytes", "4096"),
            ],
        );
        let (status, error) = canonical_error(&headroom);
        assert_eq!(status, 429);
        assert_eq!(
            error.to_json(),
            json!({
                "code": "resource_capacity_exhausted", "stage": "import_admission",
                "resource": "storage_headroom", "message": "Guest storage headroom is unavailable.",
                "available_bytes": 1024, "required_bytes": 4096,
            })
        );
        let slot = capacity(
            Code::ResourceExhausted,
            "agent-vmm",
            "RESOURCE_CAPACITY_EXHAUSTED",
            &[
                ("resource_dimension", "import_slot"),
                ("stage", "import_slot"),
            ],
        );
        assert_eq!(
            canonical_error(&slot).1.to_json(),
            json!({
                "code": "resource_capacity_exhausted", "stage": "import_slot",
                "resource": "import_slot", "message": "Guest OCI import slot is occupied.",
            })
        );
    }

    #[test]
    fn running_import_is_progress_only_under_the_host_contract() {
        let running = capacity(
            Code::Unavailable,
            "agent-vmm",
            "OPERATION_IN_PROGRESS",
            &[("stage", "image_import")],
        );
        assert_eq!(
            canonical_error(&running),
            (
                503,
                ImportError::new(
                    "import_in_progress",
                    "runtime",
                    "Image import is in progress."
                )
            )
        );
        for (code, domain, reason) in [
            (Code::Internal, "agent-vmm", "OPERATION_IN_PROGRESS"),
            (Code::Unavailable, "other", "OPERATION_IN_PROGRESS"),
            (Code::Unavailable, "agent-vmm", "OTHER"),
        ] {
            assert_ne!(
                canonical_error(&capacity(code, domain, reason, &[])).1.code,
                "import_in_progress"
            );
        }
    }

    #[test]
    fn corrupt_artifacts_and_legacy_headroom_keep_their_actionable_identity() {
        for (code, expected) in [
            (Code::DataLoss, "data_loss"),
            (Code::InvalidArgument, "invalid_argument"),
            (Code::NotFound, "not_found"),
            (Code::PermissionDenied, "permission_denied"),
        ] {
            let error = canonical_error(&Status::new(code, "private details")).1;
            assert_eq!(error.code, expected);
            assert_eq!(error.resource, "image");
            assert_eq!(error.stage, "image_import");
        }
        let error = canonical_error(&capacity(
            Code::ResourceExhausted,
            "agent-vmm",
            "RESOURCE_CAPACITY_EXHAUSTED",
            &[
                ("resource_dimension", "storage_headroom"),
                ("stage", "vm_capacity"),
            ],
        ))
        .1;
        assert_eq!(error.code, "resource_capacity_exhausted");
        assert_eq!(error.stage, "import_admission");
        assert_eq!(error.resource, "storage_headroom");
    }

    #[test]
    fn unowned_or_mismatched_details_stay_generic() {
        let generic = json!({
            "code": "resource_exhausted", "stage": "image_import", "resource": "runtime",
            "message": "Image import capacity is unavailable.",
        });
        for status in [
            capacity(
                Code::ResourceExhausted,
                "other",
                "RESOURCE_CAPACITY_EXHAUSTED",
                &[
                    ("resource_dimension", "storage_headroom"),
                    ("stage", "import_admission"),
                ],
            ),
            capacity(
                Code::ResourceExhausted,
                "agent-vmm",
                "OTHER",
                &[
                    ("resource_dimension", "storage_headroom"),
                    ("stage", "import_admission"),
                ],
            ),
            capacity(
                Code::ResourceExhausted,
                "agent-vmm",
                "RESOURCE_CAPACITY_EXHAUSTED",
                &[
                    ("resource_dimension", "storage_headroom"),
                    ("stage", "import_slot"),
                ],
            ),
            capacity(
                Code::ResourceExhausted,
                "agent-vmm",
                "RESOURCE_CAPACITY_EXHAUSTED",
                &[
                    ("resource_dimension", "pids"),
                    ("stage", "import_admission"),
                ],
            ),
        ] {
            assert_eq!(canonical_error(&status).1.to_json(), generic);
        }
        // The right details under another status code grant nothing either.
        let wrong_code = capacity(
            Code::FailedPrecondition,
            "agent-vmm",
            "RESOURCE_CAPACITY_EXHAUSTED",
            &[
                ("resource_dimension", "storage_headroom"),
                ("stage", "import_admission"),
            ],
        );
        assert_eq!(
            canonical_error(&wrong_code),
            (
                409,
                ImportError::new(
                    "failed_precondition",
                    "runtime",
                    "Image import precondition failed."
                )
            )
        );
        let internal = canonical_error(&Status::new(Code::Internal, "boom"));
        assert_eq!(
            internal,
            (
                502,
                ImportError::new("image_import_failed", "image", "Image import failed.")
            )
        );
        assert_eq!(
            interrupted_error(Code::Canceled),
            (
                408,
                ImportError::new("canceled", "runtime", "Image import was canceled.")
            )
        );
        assert_eq!(interrupted_error(Code::DeadlineExceeded).0, 504);
    }
}
