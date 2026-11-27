//! `agent-vmm/rpc/1`: one call per byte stream. Every frame is a tag byte, a
//! big-endian `u32` length and that many bytes.

use crate::status::{Code, Status};
use prost::Message;
use serde::{Deserialize, Serialize};
use std::{io, pin::pin, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    time::{Instant, timeout, timeout_at},
};

pub const ALPN: &[u8] = b"agent-vmm/rpc/1";
pub const TAG_HEADER: u8 = 0x00;
pub const TAG_MSG: u8 = 0x01;
pub const TAG_END: u8 = 0x02;
pub const TAG_STATUS: u8 = 0x03;
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_HEADER_BYTES: usize = 64 * 1024;
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);

pub type BoxRead = Box<dyn AsyncRead + Send + Unpin>;
pub type BoxWrite = Box<dyn AsyncWrite + Send + Unpin>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RequestHeader {
    pub v: u32,
    pub method: String,
    #[serde(default)]
    pub metadata: Vec<(String, String)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

impl RequestHeader {
    /// Every value of one metadata key.
    pub fn values<'a>(&'a self, key: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.metadata
            .iter()
            .filter(move |(name, _)| name == key)
            .map(|(_, value)| value.as_str())
    }
}

pub async fn read_frame<R: AsyncRead + Unpin + ?Sized>(
    reader: &mut R,
) -> io::Result<Option<(u8, Vec<u8>)>> {
    let mut tag = [0u8; 1];
    if reader.read(&mut tag).await? == 0 {
        return Ok(None);
    }
    let mut length = [0u8; 4];
    reader.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    let limit = match tag[0] {
        TAG_HEADER => MAX_HEADER_BYTES,
        // A status carries an encoded `google.rpc.Status` in its details.
        TAG_MSG | TAG_STATUS => MAX_FRAME_BYTES,
        TAG_END => 0,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unknown frame tag",
            ));
        }
    };
    if length > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds its bound",
        ));
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload).await?;
    Ok(Some((tag[0], payload)))
}

pub async fn write_frame<W: AsyncWrite + Unpin + ?Sized>(
    writer: &mut W,
    tag: u8,
    payload: &[u8],
) -> io::Result<()> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "frame exceeds its bound",
        ));
    }
    let mut head = Vec::with_capacity(5 + payload.len().min(MAX_HEADER_BYTES));
    head.push(tag);
    head.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    if payload.len() <= MAX_HEADER_BYTES {
        head.extend_from_slice(payload);
        writer.write_all(&head).await?;
    } else {
        writer.write_all(&head).await?;
        writer.write_all(payload).await?;
    }
    writer.flush().await
}

// ---- server side ---------------------------------------------------------------

pub struct ServerCall {
    pub header: RequestHeader,
    pub rx: ServerReceiver,
    pub tx: ServerSender,
}

pub struct ServerReceiver {
    inner: BoxRead,
    ended: bool,
}

pub struct ServerSender {
    inner: BoxWrite,
}

/// Reads the request header of an inbound stream.
pub async fn accept(mut read: BoxRead, write: BoxWrite) -> io::Result<ServerCall> {
    let frame = timeout(HEADER_TIMEOUT, read_frame(&mut read))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "request header timed out"))??;
    let Some((TAG_HEADER, payload)) = frame else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "request header required",
        ));
    };
    let header: RequestHeader = serde_json::from_slice(&payload)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "request header is invalid"))?;
    if header.v != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported request header version",
        ));
    }
    Ok(ServerCall {
        header,
        rx: ServerReceiver {
            inner: read,
            ended: false,
        },
        tx: ServerSender { inner: write },
    })
}

impl ServerReceiver {
    /// The next request message, or `None` once the client ended its stream.
    pub async fn message(&mut self) -> Result<Option<Vec<u8>>, Status> {
        if self.ended {
            return Ok(None);
        }
        match read_frame(&mut self.inner).await {
            Ok(Some((TAG_MSG, payload))) => Ok(Some(payload)),
            Ok(Some((TAG_END, _))) => {
                self.ended = true;
                Ok(None)
            }
            Ok(Some(_)) => Err(Status::new(
                Code::InvalidArgument,
                "unexpected request frame",
            )),
            Ok(None) | Err(_) => Err(Status::new(Code::Canceled, "request stream closed")),
        }
    }
}

impl ServerSender {
    pub async fn message(&mut self, payload: &[u8]) -> io::Result<()> {
        write_frame(&mut self.inner, TAG_MSG, payload).await
    }

    pub async fn finish(mut self, status: &Status) -> io::Result<()> {
        write_frame(&mut self.inner, TAG_STATUS, &status.encode()).await?;
        self.inner.shutdown().await
    }
}

// ---- client side ---------------------------------------------------------------

pub struct ClientCall {
    pub tx: ClientSender,
    pub rx: ClientReceiver,
}

pub struct ClientSender {
    inner: BoxWrite,
    deadline: Option<Instant>,
}

pub struct ClientReceiver {
    inner: BoxRead,
    deadline: Option<Instant>,
    done: bool,
}

fn unavailable() -> Status {
    Status::new(Code::Unavailable, "runtime stream closed")
}

fn deadline_exceeded() -> Status {
    Status::new(Code::DeadlineExceeded, "deadline exceeded")
}

async fn bounded<T>(
    deadline: Option<Instant>,
    future: impl Future<Output = io::Result<T>>,
) -> Result<T, Status> {
    match deadline {
        Some(deadline) => timeout_at(deadline, future)
            .await
            .map_err(|_| deadline_exceeded())?
            .map_err(|_| unavailable()),
        None => future.await.map_err(|_| unavailable()),
    }
}

/// Starts a call on a stream this side opened. `deadline` bounds every later step.
pub async fn open(
    read: BoxRead,
    mut write: BoxWrite,
    method: &str,
    metadata: Vec<(String, String)>,
    deadline: Option<Instant>,
) -> Result<ClientCall, Status> {
    let timeout_ms = match deadline {
        Some(deadline) => {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(deadline_exceeded());
            }
            Some((left.as_millis() as u64).max(1))
        }
        None => None,
    };
    let header = RequestHeader {
        v: 1,
        method: method.into(),
        metadata,
        timeout_ms,
    };
    let payload = serde_json::to_vec(&header).expect("a request header is JSON");
    bounded(deadline, write_frame(&mut write, TAG_HEADER, &payload)).await?;
    Ok(ClientCall {
        tx: ClientSender {
            inner: write,
            deadline,
        },
        rx: ClientReceiver {
            inner: read,
            deadline,
            done: false,
        },
    })
}

/// Runs a call's request stream beside its answer. A peer that refuses a call
/// stops reading it: its status decides the call at once, where a sender alone
/// would wait on the unread stream window until the deadline. A failed send
/// leaves the answer to say why.
pub async fn exchange<T, E>(
    send: impl Future<Output = Result<(), Status>>,
    answer: impl Future<Output = Result<T, E>>,
) -> Result<T, E> {
    let mut answer = pin!(answer);
    tokio::select! {
        biased;
        answer = &mut answer => return answer,
        _sent = send => {}
    }
    answer.await
}

impl ClientSender {
    pub async fn send<M: Message>(&mut self, message: &M) -> Result<(), Status> {
        let payload = message.encode_to_vec();
        bounded(
            self.deadline,
            write_frame(&mut self.inner, TAG_MSG, &payload),
        )
        .await
    }

    /// Ends the request stream.
    pub async fn close(&mut self) -> Result<(), Status> {
        bounded(self.deadline, write_frame(&mut self.inner, TAG_END, &[])).await
    }
}

impl ClientReceiver {
    /// The next response message; `None` after an OK status; the status otherwise.
    pub async fn message<M: Message + Default>(&mut self) -> Result<Option<M>, Status> {
        if self.done {
            return Ok(None);
        }
        let frame = bounded(self.deadline, read_frame(&mut self.inner)).await;
        match frame {
            Ok(Some((TAG_MSG, payload))) => M::decode(payload.as_slice())
                .map(Some)
                .map_err(|_| Status::new(Code::Internal, "response message is invalid")),
            Ok(Some((TAG_STATUS, payload))) => {
                self.done = true;
                match Status::decode(&payload) {
                    Some(status) if status.is_ok() => Ok(None),
                    Some(status) => Err(status),
                    None => Err(Status::new(Code::Internal, "response status is invalid")),
                }
            }
            Ok(Some(_)) => {
                self.done = true;
                Err(Status::new(Code::Internal, "unexpected response frame"))
            }
            Ok(None) => {
                self.done = true;
                Err(unavailable())
            }
            Err(status) => {
                self.done = true;
                Err(status)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn frames_keep_their_tag_length_and_bounds() {
        let mut bytes = Vec::new();
        write_frame(&mut bytes, TAG_MSG, b"").await.unwrap();
        write_frame(&mut bytes, TAG_MSG, b"abc").await.unwrap();
        write_frame(&mut bytes, TAG_END, b"").await.unwrap();
        assert_eq!(
            bytes,
            [
                1, 0, 0, 0, 0, 1, 0, 0, 0, 3, b'a', b'b', b'c', 2, 0, 0, 0, 0
            ]
        );

        let mut reader = bytes.as_slice();
        assert_eq!(
            read_frame(&mut reader).await.unwrap(),
            Some((TAG_MSG, vec![]))
        );
        assert_eq!(
            read_frame(&mut reader).await.unwrap(),
            Some((TAG_MSG, b"abc".to_vec()))
        );
        assert_eq!(
            read_frame(&mut reader).await.unwrap(),
            Some((TAG_END, vec![]))
        );
        assert_eq!(read_frame(&mut reader).await.unwrap(), None);

        // A header may not exceed 64 KiB, an end frame carries nothing, and no tag is unknown.
        let oversized = [
            &[TAG_HEADER][..],
            &(MAX_HEADER_BYTES as u32 + 1).to_be_bytes(),
        ]
        .concat();
        assert!(read_frame(&mut oversized.as_slice()).await.is_err());
        assert!(
            read_frame(&mut [TAG_END, 0, 0, 0, 1, 0].as_slice())
                .await
                .is_err()
        );
        assert!(read_frame(&mut [9u8, 0, 0, 0, 0].as_slice()).await.is_err());
    }

    #[test]
    fn request_header_matches_the_wire_contract() {
        let header: RequestHeader = serde_json::from_str(
            r#"{"v":1,"method":"/a.B/C","metadata":[["authorization","Bearer x"]],"timeout_ms":30000}"#,
        )
        .unwrap();
        assert_eq!(
            header.values("authorization").collect::<Vec<_>>(),
            ["Bearer x"]
        );
        assert_eq!(header.timeout_ms, Some(30000));
        let bare: RequestHeader = serde_json::from_str(r#"{"v":1,"method":"/a.B/C"}"#).unwrap();
        assert!(bare.metadata.is_empty() && bare.timeout_ms.is_none());
        assert_eq!(
            serde_json::to_string(&bare).unwrap(),
            r#"{"v":1,"method":"/a.B/C","metadata":[]}"#
        );
    }
}
