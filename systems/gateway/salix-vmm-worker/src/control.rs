//! The worker's side of its stdio channel to Salix. Every frame is a
//! big-endian `u32` length and one JSON object (`{:packet, 4}`):
//!
//! * `{"type":"call","id":N,"op":…,"body":…}` asks Salix for a control decision;
//! * `{"type":"reply","id":N,"status":S,"body":…}` is its answer, shaped as the
//!   former gateway control HTTP API answered (a status and a JSON body);
//! * `{"type":"ready",…}` and `{"type":"event",…}` tell Salix what happened here.

use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;

/// A reply may carry a signed registry snapshot.
pub const MAX_PACKET_BYTES: usize = 32 * 1024 * 1024;
/// The bound the gateway's control HTTP client had.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlError {
    /// Salix answered with a status outside 2xx.
    Status { status: u16, reason: String },
    /// No answer: Salix is gone or took too long.
    Transport,
}

impl ControlError {
    pub fn status(&self) -> Option<(u16, &str)> {
        match self {
            Self::Status { status, reason } => Some((*status, reason.as_str())),
            Self::Transport => None,
        }
    }
}

impl std::fmt::Display for ControlError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Status { status, reason } if reason.is_empty() => {
                write!(formatter, "control status {status}")
            }
            Self::Status { status, reason } => {
                write!(formatter, "control status {status}: {reason}")
            }
            Self::Transport => write!(formatter, "control unavailable"),
        }
    }
}

pub async fn read_packet<R: AsyncRead + Unpin>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut length = [0u8; 4];
    match reader.read_exact(&mut length).await {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let length = u32::from_be_bytes(length) as usize;
    if length > MAX_PACKET_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet exceeds its bound",
        ));
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload).await?;
    Ok(Some(payload))
}

pub async fn write_packet<W: AsyncWrite + Unpin>(writer: &mut W, payload: &[u8]) -> io::Result<()> {
    writer
        .write_all(&(payload.len() as u32).to_be_bytes())
        .await?;
    writer.write_all(payload).await?;
    writer.flush().await
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<(u16, Value)>>>>;

pub struct Control {
    out: mpsc::Sender<Vec<u8>>,
    pending: Pending,
    next: AtomicU64,
    closed: CancellationToken,
}

impl Control {
    /// Takes the channel over. `shutdown` is cancelled when Salix closes its end.
    pub fn start<R, W>(mut reader: R, mut writer: W, shutdown: CancellationToken) -> Arc<Self>
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out, mut frames) = mpsc::channel::<Vec<u8>>(256);
        let pending: Pending = Arc::default();
        let stop = shutdown.clone();
        tokio::spawn(async move {
            while let Some(frame) = frames.recv().await {
                if write_packet(&mut writer, &frame).await.is_err() {
                    stop.cancel();
                    return;
                }
            }
        });
        let replies = pending.clone();
        let closed = shutdown.clone();
        tokio::spawn(async move {
            while let Ok(Some(packet)) = read_packet(&mut reader).await {
                let Ok(reply) = serde_json::from_slice::<Value>(&packet) else {
                    continue;
                };
                let (Some(id), Some(status)) = (reply["id"].as_u64(), reply["status"].as_u64())
                else {
                    continue;
                };
                let waiter = replies.lock().expect("pending calls").remove(&id);
                if let Some(waiter) = waiter {
                    let _ = waiter.send((status as u16, reply["body"].clone()));
                }
            }
            // Dropping the waiters fails every call still in flight.
            replies.lock().expect("pending calls").clear();
            shutdown.cancel();
        });
        Arc::new(Self {
            out,
            pending,
            next: AtomicU64::new(1),
            closed,
        })
    }

    /// One control call. `Ok(None)` is an answer without content (204).
    pub async fn call(
        &self,
        op: &'static str,
        body: Value,
        limit: Duration,
    ) -> Result<Option<Value>, ControlError> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (reply, answered) = oneshot::channel();
        self.pending
            .lock()
            .expect("pending calls")
            .insert(id, reply);
        let frame = json!({"type": "call", "id": id, "op": op, "body": body});
        let frame = serde_json::to_vec(&frame).expect("a control call is JSON");
        let answer = tokio::time::timeout(limit, async {
            self.out.send(frame).await.map_err(|_| ())?;
            tokio::select! {
                answer = answered => answer.map_err(|_| ()),
                // Salix has left: nothing answers any more.
                _ = self.closed.cancelled() => Err(()),
            }
        })
        .await;
        let (status, body) = match answer {
            Ok(Ok(answer)) => answer,
            _ => {
                self.pending.lock().expect("pending calls").remove(&id);
                return Err(ControlError::Transport);
            }
        };
        match status {
            204 => Ok(None),
            200..=299 => Ok(Some(body)),
            _ => {
                let reason = body["reason"]
                    .as_str()
                    .filter(|reason| !reason.is_empty())
                    .or_else(|| body["error"].as_str())
                    .unwrap_or_default();
                Err(ControlError::Status {
                    status,
                    reason: reason.into(),
                })
            }
        }
    }

    /// Tells Salix a fact. A full channel drops it: telemetry never blocks work.
    pub fn event(&self, mut event: Value) {
        event["type"] = json!("event");
        if let Ok(frame) = serde_json::to_vec(&event) {
            let _ = self.out.try_send(frame);
        }
    }

    /// Sends the one `ready` frame, ahead of anything else.
    pub async fn ready(&self, remote_addr: &str) {
        let frame = json!({"type": "ready", "remote_addr": remote_addr});
        let _ = self
            .out
            .send(serde_json::to_vec(&frame).expect("ready is JSON"))
            .await;
    }
}
