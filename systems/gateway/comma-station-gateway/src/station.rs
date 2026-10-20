//! Station connections: one iroh endpoint, one cached QUIC connection per
//! station, one bidirectional stream per tool request (`comma/tools/1`).
//!
//! Wire format (contract §8, framed like still.fail's `stillfail/admin/1`):
//! the request is one JSON header line followed by a body (empty in v1), the
//! response one JSON header line followed by a body that v1 does not use.

use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use iroh::{
    Endpoint, EndpointAddr, EndpointId, PublicKey, RelayMap, RelayMode, RelayUrl, SecretKey,
    endpoint::{Connection, RecvStream, SendStream, presets::Minimal},
};
use serde_json::Value;
use tokio::sync::Mutex;

use crate::metrics::Metrics;

pub const ALPN: &[u8] = b"comma/tools/1";
/// Largest response header line accepted. `fs.read` returns up to 8 MiB,
/// base64-encoded inside the line.
pub const MAX_RESPONSE_LINE: usize = 12 * 1024 * 1024;

/// Binds the gateway's endpoint. It accepts no inbound protocol: stations are
/// only dialed. Its home relay is the nearest of Comma's relays; a station's
/// own relay and addresses come from the Mainline DHT, where stations publish
/// them.
pub async fn bind(
    secret: SecretKey,
    relays: &[RelayUrl],
    dht_lookup: bool,
) -> anyhow::Result<Endpoint> {
    let relay_mode = if relays.is_empty() {
        RelayMode::Disabled
    } else {
        RelayMode::Custom(RelayMap::from_iter(relays.iter().cloned()))
    };
    let mut builder = Endpoint::builder(Minimal)
        .secret_key(secret)
        .relay_mode(relay_mode);
    if dht_lookup {
        builder = builder
            .address_lookup(iroh_mainline_address_lookup::DhtAddressLookup::builder().no_publish());
    }
    Ok(builder.bind().await?)
}

/// Station id (hex of its Ed25519 public key) to iroh endpoint id.
pub fn parse_station_id(id: &str) -> Option<EndpointId> {
    if id.len() != 64 {
        return None;
    }
    let bytes: [u8; 32] = hex::decode(id).ok()?.try_into().ok()?;
    PublicKey::from_bytes(&bytes).ok()
}

/// Why a tool request produced no station response.
#[derive(Debug)]
pub enum CallError {
    /// No connection or stream could be opened: the request never reached the
    /// station.
    Unreachable(String),
    /// The connection or stream failed after the request was written; the
    /// station may or may not have run it.
    Disconnected(String),
    /// The deadline passed after the request started to be written and
    /// before the response line arrived; the station may have run it. A
    /// deadline that passes before anything is sent is `Unreachable`.
    Timeout,
    /// The station answered with something that is not a §8 response header.
    BadResponse(String),
}

struct Slot {
    connection: Mutex<Option<Connection>>,
    last_used_ms: AtomicU64,
}

pub struct Stations {
    endpoint: Endpoint,
    slots: Mutex<HashMap<EndpointId, Arc<Slot>>>,
    connect_timeout: Duration,
    max_connections: usize,
    started: Instant,
    metrics: Arc<Metrics>,
}

impl Stations {
    pub fn new(
        endpoint: Endpoint,
        connect_timeout: Duration,
        max_connections: usize,
        metrics: Arc<Metrics>,
    ) -> Self {
        Self {
            endpoint,
            slots: Mutex::new(HashMap::new()),
            connect_timeout,
            max_connections,
            started: Instant::now(),
            metrics,
        }
    }

    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// Sends one request header and returns the station's response header.
    /// A request is written at most once: nothing is retried after its first
    /// byte may have left, because tool ops such as `exec` are not idempotent.
    pub async fn call(
        &self,
        station: EndpointId,
        header: &[u8],
        deadline: Instant,
    ) -> Result<Value, CallError> {
        let slot = self.slot(station).await;
        slot.last_used_ms.store(self.now_ms(), Ordering::Relaxed);
        let (send, recv) = self.open_stream(&slot, station, deadline).await?;
        let result = exchange(send, recv, header, deadline).await;
        slot.last_used_ms.store(self.now_ms(), Ordering::Relaxed);
        result
    }

    /// A stream on the cached connection, or on a new one. A cached connection
    /// that fails to open a stream is replaced once: no request byte was sent.
    async fn open_stream(
        &self,
        slot: &Slot,
        station: EndpointId,
        deadline: Instant,
    ) -> Result<(SendStream, RecvStream), CallError> {
        let (connection, cached) = self.connection(slot, station, deadline).await?;
        match timeout_at(deadline, connection.open_bi()).await {
            Some(Ok(pair)) => return Ok(pair),
            Some(Err(error)) if !cached => return Err(CallError::Unreachable(error.to_string())),
            Some(Err(_)) => {}
            None => return Err(not_sent_by_deadline()),
        }
        self.forget(slot, &connection).await;
        let (connection, _) = self.connection(slot, station, deadline).await?;
        match timeout_at(deadline, connection.open_bi()).await {
            Some(Ok(pair)) => Ok(pair),
            Some(Err(error)) => Err(CallError::Unreachable(error.to_string())),
            None => Err(not_sent_by_deadline()),
        }
    }

    /// The live connection to a station, dialing it if there is none. Dialing
    /// holds the slot's lock, so concurrent requests share one attempt.
    async fn connection(
        &self,
        slot: &Slot,
        station: EndpointId,
        deadline: Instant,
    ) -> Result<(Connection, bool), CallError> {
        let mut guard = slot.connection.lock().await;
        if let Some(connection) = guard.as_ref() {
            if connection.close_reason().is_none() {
                return Ok((connection.clone(), true));
            }
            *guard = None;
            self.metrics.connections.dec();
        }
        let connect_deadline = deadline.min(Instant::now() + self.connect_timeout);
        let dialed = timeout_at(
            connect_deadline,
            self.endpoint.connect(EndpointAddr::from(station), ALPN),
        )
        .await;
        let connection = match dialed {
            Some(Ok(connection)) => connection,
            Some(Err(error)) => {
                self.metrics.connect(false);
                return Err(CallError::Unreachable(error.to_string()));
            }
            None => {
                self.metrics.connect(false);
                return Err(if connect_deadline < deadline {
                    CallError::Unreachable("connect timed out".into())
                } else {
                    not_sent_by_deadline()
                });
            }
        };
        self.metrics.connect(true);
        self.metrics.connections.inc();
        *guard = Some(connection.clone());
        Ok((connection, false))
    }

    async fn forget(&self, slot: &Slot, failed: &Connection) {
        let mut guard = slot.connection.lock().await;
        if guard
            .as_ref()
            .is_some_and(|c| c.stable_id() == failed.stable_id())
        {
            failed.close(0u32.into(), b"stream open failed");
            *guard = None;
            self.metrics.connections.dec();
        }
    }

    async fn slot(&self, station: EndpointId) -> Arc<Slot> {
        let mut slots = self.slots.lock().await;
        if let Some(slot) = slots.get(&station) {
            return slot.clone();
        }
        if slots.len() >= self.max_connections {
            self.evict_one(&mut slots);
        }
        let slot = Arc::new(Slot {
            connection: Mutex::new(None),
            last_used_ms: AtomicU64::new(self.now_ms()),
        });
        slots.insert(station, slot.clone());
        slot
    }

    /// Drops the least recently used slot that no request is using.
    fn evict_one(&self, slots: &mut HashMap<EndpointId, Arc<Slot>>) {
        let victim = slots
            .iter()
            .filter(|(_, slot)| Arc::strong_count(slot) == 1)
            .min_by_key(|(_, slot)| slot.last_used_ms.load(Ordering::Relaxed))
            .map(|(id, _)| *id);
        if let Some(id) = victim
            && let Some(slot) = slots.remove(&id)
        {
            self.close_slot(&slot, b"evicted");
        }
    }

    /// Closes connections unused for `idle`. Run periodically.
    pub async fn sweep_idle(&self, idle: Duration) {
        let cutoff = self.now_ms().saturating_sub(idle.as_millis() as u64);
        let mut slots = self.slots.lock().await;
        slots.retain(|_, slot| {
            let idle =
                Arc::strong_count(slot) == 1 && slot.last_used_ms.load(Ordering::Relaxed) < cutoff;
            if idle {
                self.close_slot(slot, b"idle");
            }
            !idle
        });
    }

    fn close_slot(&self, slot: &Slot, reason: &[u8]) {
        if let Ok(mut guard) = slot.connection.try_lock()
            && let Some(connection) = guard.take()
        {
            connection.close(0u32.into(), reason);
            self.metrics.connections.dec();
        }
    }

    /// Stations with a cached connection object (live or not yet swept).
    pub async fn cached(&self) -> usize {
        self.slots.lock().await.len()
    }

    fn now_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }
}

async fn exchange(
    mut send: SendStream,
    mut recv: RecvStream,
    header: &[u8],
    deadline: Instant,
) -> Result<Value, CallError> {
    let written = timeout_at(deadline, async {
        send.write_all(header).await?;
        send.write_all(b"\n").await?;
        send.finish()?;
        anyhow::Ok(())
    })
    .await;
    match written {
        Some(Ok(())) => {}
        Some(Err(error)) => return Err(CallError::Disconnected(error.to_string())),
        None => {
            let _ = send.reset(0u32.into());
            let _ = recv.stop(0u32.into());
            return Err(CallError::Timeout);
        }
    }
    let line = match timeout_at(deadline, read_line(&mut recv)).await {
        Some(Ok(line)) => line,
        Some(Err(error)) => return Err(error),
        None => {
            let _ = recv.stop(0u32.into());
            return Err(CallError::Timeout);
        }
    };
    // v1 responses carry everything in the header line; any body is unused.
    let _ = recv.stop(0u32.into());
    let response: Value = serde_json::from_slice(&line)
        .map_err(|e| CallError::BadResponse(format!("response header is not JSON: {e}")))?;
    match response.get("ok") {
        Some(Value::Bool(true)) if response.get("result").is_some() => Ok(response),
        Some(Value::Bool(false)) if response.get("error").is_some_and(Value::is_object) => {
            Ok(response)
        }
        _ => Err(CallError::BadResponse(
            "response header lacks ok/result or ok/error".into(),
        )),
    }
}

async fn read_line(recv: &mut RecvStream) -> Result<Vec<u8>, CallError> {
    let mut line = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = match recv.read(&mut buf).await {
            Ok(Some(n)) => n,
            Ok(None) if line.is_empty() => {
                return Err(CallError::Disconnected(
                    "station closed the stream without a response".into(),
                ));
            }
            Ok(None) => {
                return Err(CallError::BadResponse(
                    "response ended inside its header line".into(),
                ));
            }
            Err(error) => return Err(CallError::Disconnected(error.to_string())),
        };
        if let Some(end) = buf[..n].iter().position(|b| *b == b'\n') {
            line.extend_from_slice(&buf[..end]);
            return Ok(line);
        }
        line.extend_from_slice(&buf[..n]);
        if line.len() > MAX_RESPONSE_LINE {
            return Err(CallError::BadResponse(
                "response header line is too large".into(),
            ));
        }
    }
}

/// The request deadline passed while connecting or opening a stream, so
/// nothing was sent.
fn not_sent_by_deadline() -> CallError {
    CallError::Unreachable("no connection to the station before the deadline".into())
}

async fn timeout_at<F: std::future::Future>(deadline: Instant, future: F) -> Option<F::Output> {
    tokio::time::timeout_at(deadline.into(), future).await.ok()
}
