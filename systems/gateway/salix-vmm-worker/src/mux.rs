//! One `yamux` connection: inbound streams for the peer's calls, outbound
//! streams for this side's.

use crate::{
    rpc::{BoxRead, BoxWrite},
    status::{Code, Status},
};
use std::{
    collections::VecDeque,
    future::poll_fn,
    io,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{mpsc, oneshot},
};
use tokio_util::{
    compat::{FuturesAsyncReadCompatExt, TokioAsyncReadCompatExt},
    sync::CancellationToken,
};

/// The largest slice one `poll_write` hands a `yamux::Stream`. yamux turns a
/// write into one data frame and reads nothing while that frame is half
/// written, so two peers that both send large messages would stop each other
/// once the socket buffers fill. Small frames keep both directions moving.
const WRITE_CHUNK: usize = 8192;
/// Streams of both directions on one connection. yamux needs its connection
/// receive window (1 GiB by default) to cover 256 KiB for each.
const MAX_STREAMS: usize = 2048;

pub type Stream = (BoxRead, BoxWrite);

#[derive(Clone)]
pub struct MuxHandle {
    open: mpsc::Sender<oneshot::Sender<yamux::Stream>>,
    closed: CancellationToken,
}

impl MuxHandle {
    /// Opens a stream to the peer.
    pub async fn open(&self) -> Result<Stream, Status> {
        let unavailable = || Status::new(Code::Unavailable, "host connection closed");
        let (reply, opened) = oneshot::channel();
        tokio::select! {
            sent = self.open.send(reply) => sent.map_err(|_| unavailable())?,
            _ = self.closed.cancelled() => return Err(unavailable()),
        }
        tokio::select! {
            stream = opened => stream.map(split).map_err(|_| unavailable()),
            _ = self.closed.cancelled() => Err(unavailable()),
        }
    }

    /// Cancelled once the connection has ended.
    pub fn closed(&self) -> &CancellationToken {
        &self.closed
    }

    pub fn close(&self) {
        self.closed.cancel();
    }
}

fn split(stream: yamux::Stream) -> Stream {
    let (read, write) = tokio::io::split(stream.compat());
    (Box::new(read), Box::new(ChunkedWrite(write)))
}

struct ChunkedWrite<W>(W);

impl<W: AsyncWrite + Unpin> AsyncWrite for ChunkedWrite<W> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let bytes = &bytes[..bytes.len().min(WRITE_CHUNK)];
        Pin::new(&mut self.0).poll_write(cx, bytes)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

/// Drives the connection until it ends or the handle is closed. Inbound
/// streams beyond `inbound_backlog` waiting ones are reset.
pub fn spawn<T>(
    io: T,
    mode: yamux::Mode,
    inbound_backlog: usize,
) -> (MuxHandle, mpsc::Receiver<Stream>)
where
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (open_tx, mut open_rx) = mpsc::channel::<oneshot::Sender<yamux::Stream>>(64);
    let (inbound_tx, inbound_rx) = mpsc::channel(inbound_backlog);
    let closed = CancellationToken::new();
    let handle = MuxHandle {
        open: open_tx,
        closed: closed.clone(),
    };
    tokio::spawn(async move {
        let mut config = yamux::Config::default();
        config.set_max_num_streams(MAX_STREAMS);
        let mut connection = yamux::Connection::new(io.compat(), config, mode);
        let mut waiting: VecDeque<oneshot::Sender<yamux::Stream>> = VecDeque::new();
        let mut open_closed = false;
        let drive = poll_fn(|cx| {
            loop {
                while !open_closed {
                    match open_rx.poll_recv(cx) {
                        Poll::Ready(Some(reply)) => waiting.push_back(reply),
                        Poll::Ready(None) => open_closed = true,
                        Poll::Pending => break,
                    }
                }
                while !waiting.is_empty() {
                    match connection.poll_new_outbound(cx) {
                        Poll::Ready(Ok(stream)) => {
                            if let Some(reply) = waiting.pop_front() {
                                let _ = reply.send(stream);
                            }
                        }
                        Poll::Ready(Err(_)) => return Poll::Ready(()),
                        Poll::Pending => break,
                    }
                }
                // The peer's streams are served for as long as it stays connected,
                // whether or not this side still opens any.
                match connection.poll_next_inbound(cx) {
                    Poll::Ready(Some(Ok(stream))) => {
                        let _ = inbound_tx.try_send(split(stream));
                    }
                    Poll::Ready(Some(Err(_))) | Poll::Ready(None) => return Poll::Ready(()),
                    Poll::Pending => return Poll::Pending,
                }
            }
        });
        tokio::select! {
            _ = drive => {}
            _ = closed.cancelled() => {}
        }
        closed.cancel();
    });
    (handle, inbound_rx)
}
