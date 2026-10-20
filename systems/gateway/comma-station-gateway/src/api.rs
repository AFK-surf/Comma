//! HTTP surface (contract §9).
//!
//! `POST /v1/stations/{station_id}/tools` with `authorization: Bearer <token>`
//! and body `{op, args, context, id?}`. Status codes:
//! - 200: the station answered; the body is its §8 response header
//!   (`{"ok":true,"result":…}` or `{"ok":false,"error":…}`).
//! - 400 invalid request, 401 bad token, 503 too many requests in flight.
//! - 502 `station_unreachable`: nothing was sent (no connection or stream,
//!   also when the deadline passes before one opens); safe to retry.
//! - 502 `station_disconnected` / `bad_station_response`: the request was
//!   sent; the op's outcome is unknown.
//! - 504 `timeout`: the request was sent and no answer came before the
//!   deadline; the op's outcome is unknown.
//!
//! Every non-200 body has the same `{"ok":false,"error":{"code","message"}}`
//! shape as a station error.

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use subtle::ConstantTimeEq;
use tokio::sync::Semaphore;

use crate::{
    config::Timeouts,
    metrics::Metrics,
    station::{CallError, Stations, parse_station_id},
};

/// `fs.write` carries up to 8 MiB base64-encoded in `args`.
const MAX_BODY: usize = 12 * 1024 * 1024;
/// Extra time over an op's own `timeout_ms` for the station to report it.
const OP_TIMEOUT_GRACE: Duration = Duration::from_secs(15);

#[derive(Clone)]
pub struct AppState {
    pub stations: Arc<Stations>,
    pub metrics: Arc<Metrics>,
    pub token: Arc<str>,
    pub timeouts: Timeouts,
    pub slots: Arc<Semaphore>,
}

pub fn api_router(state: AppState) -> Router {
    Router::new()
        .route("/v1/stations/{station_id}/tools", post(tools))
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(state)
}

pub fn admin_router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/readyz", get(ready))
        .route("/metrics", get(metrics))
        .with_state(state)
}

async fn ready(State(state): State<AppState>) -> Response {
    if state.stations.endpoint().is_closed() {
        (StatusCode::SERVICE_UNAVAILABLE, "endpoint closed").into_response()
    } else {
        "ok".into_response()
    }
}

async fn metrics(State(state): State<AppState>) -> Response {
    (
        [(
            header::CONTENT_TYPE,
            "application/openmetrics-text; version=1.0.0; charset=utf-8",
        )],
        state.metrics.render(),
    )
        .into_response()
}

#[derive(Deserialize)]
struct ToolRequest {
    op: String,
    #[serde(default)]
    args: Option<Value>,
    context: Value,
    #[serde(default)]
    id: Option<String>,
}

async fn tools(
    State(state): State<AppState>,
    Path(station_id): Path<String>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let started = Instant::now();
    if !authorized(&headers, &state.token) {
        state.metrics.request("", "unauthorized", started.elapsed());
        return failure(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "missing or invalid bearer token",
            None,
        );
    }
    let Some(station) = parse_station_id(&station_id) else {
        state
            .metrics
            .request("", "invalid_request", started.elapsed());
        return failure(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "station id must be 64 hex characters",
            None,
        );
    };
    let request: ToolRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => {
            state
                .metrics
                .request("", "invalid_request", started.elapsed());
            return failure(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                &format!("invalid body: {error}"),
                None,
            );
        }
    };
    let args = request.args.unwrap_or_else(|| Value::Object(Map::new()));
    if request.op.trim().is_empty() || !args.is_object() || !request.context.is_object() {
        state
            .metrics
            .request(&request.op, "invalid_request", started.elapsed());
        return failure(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "op must be non-empty; args and context must be objects",
            None,
        );
    }
    let id = request
        .id
        .filter(|id| !id.is_empty() && id.len() <= 128)
        .or_else(|| {
            headers
                .get("x-request-id")
                .and_then(|v| v.to_str().ok())
                .filter(|v| !v.is_empty() && v.len() <= 128)
                .map(str::to_string)
        })
        .unwrap_or_else(new_request_id);
    let Ok(_permit) = state.slots.clone().try_acquire_owned() else {
        state
            .metrics
            .request(&request.op, "overloaded", started.elapsed());
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "overloaded",
            "too many tool requests in flight",
            Some(&id),
        );
    };
    state.metrics.in_flight.inc();
    let deadline = started + request_timeout(&state.timeouts, &args);
    let header = json!({"op": request.op, "id": id, "context": request.context, "args": args});
    let header = serde_json::to_vec(&header).expect("JSON values serialize");
    let result = state.stations.call(station, &header, deadline).await;
    state.metrics.in_flight.dec();

    let (response, outcome) = match result {
        Ok(response) => {
            let outcome = if response["ok"] == Value::Bool(true) {
                "ok"
            } else {
                "tool_error"
            };
            let mut reply = Json(response).into_response();
            set_request_id(&mut reply, &id);
            (reply, outcome)
        }
        Err(CallError::Unreachable(reason)) => (
            failure(
                StatusCode::BAD_GATEWAY,
                "station_unreachable",
                &format!("station is unreachable; the request was not sent: {reason}"),
                Some(&id),
            ),
            "unreachable",
        ),
        Err(CallError::Disconnected(reason)) => (
            failure(
                StatusCode::BAD_GATEWAY,
                "station_disconnected",
                &format!("connection lost after the request was sent; outcome unknown: {reason}"),
                Some(&id),
            ),
            "disconnected",
        ),
        Err(CallError::BadResponse(reason)) => (
            failure(
                StatusCode::BAD_GATEWAY,
                "bad_station_response",
                &reason,
                Some(&id),
            ),
            "bad_response",
        ),
        Err(CallError::Timeout) => (
            failure(
                StatusCode::GATEWAY_TIMEOUT,
                "timeout",
                "request was sent but the station did not answer before the deadline; outcome unknown",
                Some(&id),
            ),
            "timeout",
        ),
    };
    let elapsed = started.elapsed();
    state.metrics.request(&request.op, outcome, elapsed);
    tracing::info!(
        station = %station.fmt_short(),
        op = %request.op,
        request_id = %id,
        outcome,
        duration_ms = elapsed.as_millis() as u64,
        "tool request"
    );
    response
}

/// The default deadline, or longer when the op asks for its own
/// `timeout_ms` (exec), capped by the configured maximum.
fn request_timeout(timeouts: &Timeouts, args: &Value) -> Duration {
    let asked = args
        .get("timeout_ms")
        .and_then(Value::as_u64)
        .map(|ms| Duration::from_millis(ms) + OP_TIMEOUT_GRACE);
    asked
        .map_or(timeouts.request, |asked| asked.max(timeouts.request))
        .min(timeouts.max_request)
}

fn authorized(headers: &HeaderMap, token: &str) -> bool {
    let Some(presented) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return false;
    };
    presented.as_bytes().ct_eq(token.as_bytes()).into()
}

fn failure(status: StatusCode, code: &str, message: &str, id: Option<&str>) -> Response {
    let mut response = (
        status,
        Json(json!({"ok": false, "error": {"code": code, "message": message}})),
    )
        .into_response();
    if let Some(id) = id {
        set_request_id(&mut response, id);
    }
    response
}

fn set_request_id(response: &mut Response, id: &str) {
    if let Ok(value) = HeaderValue::from_str(id) {
        response.headers_mut().insert("x-request-id", value);
    }
}

fn new_request_id() -> String {
    hex::encode(rand::random::<[u8; 12]>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn op_timeout_extends_the_default_up_to_the_ceiling() {
        let timeouts = Timeouts {
            request: Duration::from_secs(60),
            max_request: Duration::from_secs(600),
            ..Timeouts::default()
        };
        assert_eq!(
            request_timeout(&timeouts, &json!({})),
            Duration::from_secs(60)
        );
        assert_eq!(
            request_timeout(&timeouts, &json!({"timeout_ms": 1000})),
            Duration::from_secs(60)
        );
        assert_eq!(
            request_timeout(&timeouts, &json!({"timeout_ms": 300_000})),
            Duration::from_secs(315)
        );
        assert_eq!(
            request_timeout(&timeouts, &json!({"timeout_ms": 10_000_000})),
            Duration::from_secs(600)
        );
    }
}
