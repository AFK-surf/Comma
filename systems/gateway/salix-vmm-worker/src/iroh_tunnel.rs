//! Outbound iroh service tunnels. The worker owns transport only: the
//! destination Host authorizes each `ServiceRouteService` call by its signed
//! route capability.

use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt},
    sync::{OnceCell, OwnedSemaphorePermit, Semaphore},
};

pub const ALPN: &[u8] = b"agent-vmm/service-tunnel/1";
pub const MAX_ADDRESS_BYTES: usize = 8190;
const MAX_TUNNELS: usize = 64;
const DIAL_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_LIFETIME: Duration = Duration::from_secs(60 * 60);
const CALLER_CLOSE_GRACE: Duration = Duration::from_secs(5);

#[derive(Debug, PartialEq, Eq)]
pub enum TunnelError {
    InvalidAddress,
    CapacityExhausted,
    Unavailable,
    ConnectFailed,
}

pub struct Tunnels {
    /// `minimal` keeps the endpoint off the public relays (tests).
    preset: String,
    endpoint: OnceCell<Endpoint>,
    slots: Arc<Semaphore>,
}

pub struct Tunnel {
    connection: iroh::endpoint::Connection,
    send: iroh::endpoint::SendStream,
    receive: iroh::endpoint::RecvStream,
    _slot: OwnedSemaphorePermit,
}

impl Tunnels {
    pub fn new(preset: Option<String>) -> Self {
        Self {
            preset: preset.unwrap_or_else(|| "n0".into()),
            endpoint: OnceCell::new(),
            slots: Arc::new(Semaphore::new(MAX_TUNNELS)),
        }
    }

    pub fn active(&self) -> usize {
        MAX_TUNNELS - self.slots.available_permits()
    }

    /// The endpoint only dials: it accepts no ALPN. It is bound on first use.
    async fn endpoint(&self) -> Result<&Endpoint, TunnelError> {
        self.endpoint
            .get_or_try_init(|| async {
                let bound = if self.preset == "minimal" {
                    Endpoint::builder(presets::Minimal).bind().await
                } else {
                    Endpoint::builder(presets::N0).bind().await
                };
                bound.map_err(|_| TunnelError::Unavailable)
            })
            .await
    }

    /// Dials the endpoint and opens the one stream a tunnel carries.
    pub async fn dial(&self, address: &serde_json::Value) -> Result<Tunnel, TunnelError> {
        let encoded = serde_json::to_vec(address).map_err(|_| TunnelError::InvalidAddress)?;
        if !address.is_object() || encoded.len() > MAX_ADDRESS_BYTES {
            return Err(TunnelError::InvalidAddress);
        }
        let address: EndpointAddr =
            serde_json::from_slice(&encoded).map_err(|_| TunnelError::InvalidAddress)?;
        let slot = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| TunnelError::CapacityExhausted)?;
        let endpoint = self.endpoint().await?;
        let dialed = tokio::time::timeout(DIAL_TIMEOUT, async {
            let connection = endpoint.connect(address, ALPN).await.ok()?;
            let (send, receive) = connection.open_bi().await.ok()?;
            Some((connection, send, receive))
        })
        .await;
        match dialed {
            Ok(Some((connection, send, receive))) => Ok(Tunnel {
                connection,
                send,
                receive,
                _slot: slot,
            }),
            _ => Err(TunnelError::ConnectFailed),
        }
    }
}

impl Tunnel {
    /// Carries bytes both ways, for at most an hour. A caller that ends its
    /// request (a write half-close) still gets the peer's whole answer. Once
    /// the peer has ended its answer, a caller that does not close keeps the
    /// slot only for a short while.
    pub async fn bridge<L>(mut self, local: L)
    where
        L: AsyncRead + AsyncWrite + Unpin,
    {
        let (mut read, mut write) = tokio::io::split(local);
        let outgoing = async {
            let _ = tokio::io::copy(&mut read, &mut self.send).await;
            let _ = self.send.finish();
        };
        let incoming = async {
            let _ = tokio::io::copy(&mut self.receive, &mut write).await;
            let _ = write.shutdown().await;
        };
        let _ = tokio::time::timeout(MAX_LIFETIME, async {
            tokio::pin!(outgoing, incoming);
            tokio::select! {
                _ = &mut outgoing => incoming.await,
                _ = &mut incoming => {
                    let _ = tokio::time::timeout(CALLER_CLOSE_GRACE, outgoing).await;
                }
            }
        })
        .await;
        self.connection.close(0u32.into(), b"tunnel complete");
    }
}
