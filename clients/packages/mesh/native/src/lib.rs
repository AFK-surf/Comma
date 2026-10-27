//! The client core's iroh on the phones (clients/packages/core/src/hosts/mobile-mesh.ts), behind a C ABI the core's
//! engine calls (clients/packages/core/native/engine.cpp, the `mesh.*` operations). It is the endpoint the station's
//! addon binds for a client (systems/station/native/mesh, which the desktop app's core uses through Node): the same
//! vendored iroh, BBR with a 256 KiB first window, stations looked up in the DHT without being announced, and Salix as
//! the relay of last resort (the station's own salix.rs, and the sockets that carry its packets: carry.rs). Unlike the
//! desktop's, it does not look stations up by mDNS: a phone dials the LAN addresses the control plane says a station
//! is at (`addr.ips`), and a multicast socket on a phone needs a permission (iOS: an entitlement) for nothing more.
//!
//! Done on tokio's threads: each answer comes back through `complete(ctx, id, json, error, bytes)` from any thread. A
//! connection is let go once it closes, however it does, and a stream once it is read to its end and finished, or
//! reset.
//!
//! Operations (`op`, its JSON → its answer; `id` names a handle):
//!   mesh.bind {relayUrls, salixRelay} + key → {id, endpoint}; mesh.connect {id, addr: {id, relays?, ips?, salix?}} +
//!     alpn → {id, remote}; mesh.networkChange {id}; mesh.endpointClose {id}
//!   mesh.openBi / mesh.acceptBi {id} → {id} (acceptBi: {end} once the connection is gone); mesh.closed {id} →
//!     {reason}; mesh.close {id, code, reason}; mesh.nextVia {id, last} → {via, closed}
//!   mesh.read {id} → bytes, or {end}; mesh.write {id} + bytes; mesh.finish {id}; mesh.reset {id, code}
//!   mesh.carry {id, url, ticket} → {id} once Salix registered the endpoint on that socket; mesh.carried {id} → {}
//!     once it closed; mesh.uncarry {id}
//! `comma_mesh_abort` gives an operation up: it is never answered.

mod carry;
#[path = "../../../../../systems/station/native/mesh/src/salix.rs"]
mod salix;

use std::collections::HashMap;
use std::ffi::{CStr, c_char, c_void};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use futures_core::Stream as _;
use iroh::endpoint::{Connection, QuicTransportConfig, RecvStream, SendStream, presets::Minimal};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey};
use serde_json::{Value, json};

/// `complete(ctx, id, json, json_len, error, error_len, bytes, bytes_len, has_bytes)`: an operation's answer, its JSON
/// (when it succeeded) or its error, and its bytes if it has any. Called on any thread.
pub type Complete = extern "C" fn(*mut c_void, u64, *const u8, usize, *const u8, usize, *const u8, usize, u8);

struct Ctx(*mut c_void);
// SAFETY: the engine's context is made to be told from any thread (the C++ side queues what it is given).
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

/// An answer: JSON, and bytes where the operation has them.
struct Answer {
    json: Value,
    bytes: Option<Vec<u8>>,
}

impl Answer {
    fn json(json: Value) -> Answer {
        Answer { json, bytes: None }
    }
}

type Done = Result<Answer, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// An endpoint, and the sockets carrying its packets through Salix when it was bound to go through it.
struct Bound {
    endpoint: Endpoint,
    carriers: Option<Arc<carry::Carriers>>,
}

/// The two halves of a stream, and the reads waiting on it: a reset wakes them first (as the station's addon's).
struct Halves {
    /// The connection it is on: it goes when that one closes.
    conn: u64,
    send: tokio::sync::Mutex<SendStream>,
    recv: tokio::sync::Mutex<RecvStream>,
    reset: tokio::sync::watch::Sender<bool>,
    /// Read to its end, and finished: both, and the handle goes.
    ended: AtomicBool,
    finished: AtomicBool,
}

#[derive(Clone)]
enum Handle {
    Endpoint(Arc<Bound>),
    Conn(Connection),
    /// A connection that closed, let go (its state, its streams), with why.
    Gone(String),
    Stream(Arc<Halves>),
    Carry(Arc<carry::Socket>),
}

struct Inner {
    complete: Complete,
    ctx: Ctx,
    handles: Mutex<HashMap<u64, Handle>>,
    next: AtomicU64,
    /// The operations under way, by id: what `comma_mesh_abort` stops.
    running: Mutex<HashMap<u64, tokio::task::AbortHandle>>,
}

pub struct Mesh {
    runtime: tokio::runtime::Runtime,
    inner: Arc<Inner>,
}

fn str_of<'a>(v: &'a Value, k: &str) -> Result<&'a str, String> {
    v.get(k).and_then(Value::as_str).ok_or_else(|| format!("missing {k}"))
}

fn id_of(v: &Value) -> Result<u64, String> {
    v.get("id").and_then(Value::as_u64).ok_or_else(|| "missing id".to_string())
}

fn relay_url(url: &str) -> Result<RelayUrl, String> {
    url.parse().map_err(err)
}

fn endpoint_id(hex_id: &str) -> Result<EndpointId, String> {
    let bytes: [u8; 32] = hex::decode(hex_id).map_err(err)?.try_into().map_err(|_| "the id is not 32 bytes".to_string())?;
    EndpointId::from_bytes(&bytes).map_err(err)
}

/// Where a station is, as `addr` says: its id, its relays, its `ip:port` addresses, and whether through Salix too.
fn endpoint_addr(addr: &Value) -> Result<EndpointAddr, String> {
    let id = endpoint_id(str_of(addr, "id")?)?;
    let mut out = EndpointAddr::new(id);
    for url in addr.get("relays").and_then(Value::as_array).into_iter().flatten() {
        out = out.with_relay_url(relay_url(url.as_str().unwrap_or_default())?);
    }
    for ip in addr.get("ips").and_then(Value::as_array).into_iter().flatten() {
        out = out.with_ip_addr(ip.as_str().unwrap_or_default().parse::<std::net::SocketAddr>().map_err(err)?);
    }
    if addr.get("salix").and_then(Value::as_bool).unwrap_or(false) {
        out = out.with_addrs([salix::transport_addr(&id)]);
    }
    Ok(out)
}

/// "direct", "relay" or "salix" (the only other transport), as the station's addon says a path runs.
fn via_of(ip: bool, relay: bool) -> &'static str {
    if ip {
        "direct"
    } else if relay {
        "relay"
    } else {
        "salix"
    }
}

impl Inner {
    fn keep(&self, handle: Handle) -> u64 {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.handles.lock().unwrap().insert(id, handle);
        id
    }

    fn handle(&self, id: u64) -> Result<Handle, String> {
        self.handles.lock().unwrap().get(&id).cloned().ok_or_else(|| format!("no handle {id}"))
    }

    fn drop_handle(&self, id: u64) -> Option<Handle> {
        self.handles.lock().unwrap().remove(&id)
    }

    fn bound(&self, a: &Value) -> Result<Arc<Bound>, String> {
        match self.handle(id_of(a)?)? {
            Handle::Endpoint(bound) => Ok(bound),
            _ => Err("not an endpoint".into()),
        }
    }

    fn stream(&self, id: u64) -> Result<Arc<Halves>, String> {
        match self.handle(id)? {
            Handle::Stream(halves) => Ok(halves),
            _ => Err("not a stream".into()),
        }
    }

    /// A connection kept for the core, and let go once it closes, however it does (closed here, by the station, timed
    /// out): kept, a closed connection held its streams and iroh's tasks over them, and a phone whose links were
    /// replaced often held hundreds and grew gigabytes a minute.
    fn keep_conn(self: &Arc<Self>, conn: Connection) -> u64 {
        let id = self.keep(Handle::Conn(conn.clone()));
        let inner = self.clone();
        tokio::spawn(async move {
            let reason = conn.closed().await.to_string();
            inner.release_conn(id, reason);
        });
        id
    }

    /// A closed connection let go: why it closed is kept, and its streams go, a read still waiting on one woken.
    fn release_conn(&self, id: u64, reason: String) {
        let mut handles = self.handles.lock().unwrap();
        if !matches!(handles.get(&id), Some(Handle::Conn(_))) {
            return;
        }
        handles.insert(id, Handle::Gone(reason));
        let streams: Vec<u64> = handles.iter().filter_map(|(k, h)| matches!(h, Handle::Stream(halves) if halves.conn == id).then_some(*k)).collect();
        for k in streams {
            if let Some(Handle::Stream(halves)) = handles.remove(&k) {
                let _ = halves.reset.send(true);
            }
        }
    }

    fn stream_done(&self, id: u64, halves: &Halves) {
        if halves.ended.load(Ordering::Relaxed) && halves.finished.load(Ordering::Relaxed) {
            self.drop_handle(id);
        }
    }

    async fn run(self: &Arc<Self>, op: &str, a: Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "mesh.bind" => self.bind(&a, bytes.unwrap_or_default()).await,
            "mesh.connect" => {
                let bound = self.bound(&a)?;
                let addr = endpoint_addr(a.get("addr").ok_or("missing addr")?)?;
                let conn = bound.endpoint.connect(addr, &bytes.unwrap_or_default()).await.map_err(err)?;
                let remote = hex::encode(conn.remote_id().as_bytes());
                Ok(Answer::json(json!({ "id": self.keep_conn(conn), "remote": remote })))
            }
            "mesh.networkChange" => {
                self.bound(&a)?.endpoint.network_change().await;
                Ok(Answer::json(json!({})))
            }
            "mesh.endpointClose" => {
                if let Some(Handle::Endpoint(bound)) = self.drop_handle(id_of(&a)?) {
                    if let Some(carriers) = &bound.carriers {
                        carriers.close();
                    }
                    bound.endpoint.close().await;
                }
                Ok(Answer::json(json!({})))
            }
            "mesh.openBi" | "mesh.acceptBi" => {
                let on = id_of(&a)?;
                let conn = match self.handle(on)? {
                    Handle::Conn(conn) => conn,
                    Handle::Gone(_) if op == "mesh.acceptBi" => return Ok(Answer::json(json!({ "end": true }))),
                    Handle::Gone(reason) => return Err(format!("connection closed: {reason}")),
                    _ => return Err("not a connection".into()),
                };
                let (send, recv) = if op == "mesh.openBi" {
                    conn.open_bi().await.map_err(err)?
                } else {
                    match conn.accept_bi().await {
                        Ok(halves) => halves,
                        Err(_) => return Ok(Answer::json(json!({ "end": true }))),
                    }
                };
                let halves = Halves {
                    conn: on,
                    send: tokio::sync::Mutex::new(send),
                    recv: tokio::sync::Mutex::new(recv),
                    reset: tokio::sync::watch::channel(false).0,
                    ended: false.into(),
                    finished: false.into(),
                };
                Ok(Answer::json(json!({ "id": self.keep(Handle::Stream(Arc::new(halves))) })))
            }
            "mesh.closed" => match self.handle(id_of(&a)?)? {
                Handle::Conn(conn) => Ok(Answer::json(json!({ "reason": conn.closed().await.to_string() }))),
                Handle::Gone(reason) => Ok(Answer::json(json!({ "reason": reason }))),
                _ => Err("not a connection".into()),
            },
            "mesh.close" => {
                if let Handle::Conn(conn) = self.handle(id_of(&a)?)? {
                    let code = a.get("code").and_then(Value::as_u64).unwrap_or(0) as u32;
                    conn.close(code.into(), a.get("reason").and_then(Value::as_str).unwrap_or("").as_bytes());
                }
                Ok(Answer::json(json!({})))
            }
            // As the station's addon's `next_via`: how the connection runs once that is not `last`.
            "mesh.nextVia" => {
                let conn = match self.handle(id_of(&a)?)? {
                    Handle::Conn(conn) => conn,
                    Handle::Gone(_) => return Ok(Answer::json(json!({ "via": null, "closed": true }))),
                    _ => return Err("not a connection".into()),
                };
                let last = a.get("last").and_then(Value::as_str).map(str::to_owned);
                let mut paths = conn.paths_stream();
                loop {
                    let Some(list) = std::future::poll_fn(|cx| Pin::new(&mut paths).poll_next(cx)).await else {
                        return Ok(Answer::json(json!({ "via": null, "closed": true })));
                    };
                    let via = list.iter().find(|p| p.is_selected()).map(|p| via_of(p.is_ip(), p.is_relay()).to_string());
                    if via != last {
                        return Ok(Answer::json(json!({ "via": via, "closed": false })));
                    }
                }
            }
            "mesh.read" => {
                let id = id_of(&a)?;
                let halves = self.stream(id)?;
                let mut reset = halves.reset.subscribe();
                if *reset.borrow() {
                    return Ok(Answer::json(json!({ "end": true })));
                }
                let mut buf = vec![0u8; 64 * 1024];
                let read = {
                    let mut recv = halves.recv.lock().await;
                    tokio::select! {
                        read = recv.read(&mut buf) => read.map_err(err)?,
                        _ = reset.changed() => None,
                    }
                };
                match read {
                    Some(n) => {
                        buf.truncate(n);
                        Ok(Answer { json: json!({}), bytes: Some(buf) })
                    }
                    None => {
                        halves.ended.store(true, Ordering::Relaxed);
                        self.stream_done(id, &halves);
                        Ok(Answer::json(json!({ "end": true })))
                    }
                }
            }
            "mesh.write" => {
                let halves = self.stream(id_of(&a)?)?;
                halves.send.lock().await.write_all(&bytes.unwrap_or_default()).await.map_err(err)?;
                Ok(Answer::json(json!({})))
            }
            "mesh.finish" => {
                let id = id_of(&a)?;
                let halves = self.stream(id)?;
                halves.send.lock().await.finish().map_err(err)?;
                halves.finished.store(true, Ordering::Relaxed);
                self.stream_done(id, &halves);
                Ok(Answer::json(json!({})))
            }
            "mesh.reset" => {
                let code = a.get("code").and_then(Value::as_u64).unwrap_or(0) as u32;
                if let Some(Handle::Stream(halves)) = self.drop_handle(id_of(&a)?) {
                    // A read waiting gives up first: it holds the receiving half meanwhile.
                    let _ = halves.reset.send(true);
                    let _ = halves.send.lock().await.reset(code.into());
                    let _ = halves.recv.lock().await.stop(code.into());
                }
                Ok(Answer::json(json!({})))
            }
            "mesh.carry" => {
                let carriers = self.bound(&a)?.carriers.clone().ok_or("bound without Salix")?;
                let socket = carriers.carry(str_of(&a, "url")?, str_of(&a, "ticket")?).await?;
                Ok(Answer::json(json!({ "id": self.keep(Handle::Carry(socket)) })))
            }
            "mesh.carried" => {
                let id = id_of(&a)?;
                let Handle::Carry(socket) = self.handle(id)? else { return Err("not a socket".into()) };
                socket.closed().await;
                self.drop_handle(id);
                Ok(Answer::json(json!({})))
            }
            "mesh.uncarry" => {
                if let Handle::Carry(socket) = self.handle(id_of(&a)?)? {
                    socket.close();
                }
                Ok(Answer::json(json!({})))
            }
            other => Err(format!("no operation {other}")),
        }
    }

    /// A client's endpoint, as the station's addon binds one (lib.rs `bind`, with `lookup`) but for mDNS.
    async fn bind(self: &Arc<Self>, a: &Value, key: Vec<u8>) -> Done {
        let bytes: [u8; 32] = key.as_slice().try_into().map_err(|_| "the key is not 32 bytes".to_string())?;
        let key = SecretKey::from_bytes(&bytes);
        let relays: Vec<RelayUrl> = a.get("relayUrls").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
        // BBR paces by the bandwidth and round trip it measures: a big answer on a slow relay keeps the queue short, so
        // a handshake and a small answer behind it wait milliseconds, not seconds (systems/station/native/mesh).
        let mut bbr = noq_proto::congestion::Bbr3Config::default();
        bbr.initial_window(256 * 1024);
        let mut builder = Endpoint::builder(Minimal)
            .secret_key(key.clone())
            .relay_mode(if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(iroh::RelayMap::from_iter(relays.clone())) })
            .transport_config(QuicTransportConfig::builder().congestion_controller_factory(Arc::new(bbr)).build());
        let mut relay = None;
        if a.get("salixRelay").and_then(Value::as_bool).unwrap_or(false) {
            let (transport, queues) = salix::transport(key.public());
            builder = builder.add_custom_transport(transport);
            relay = Some(queues);
        }
        // Which relay a station is on, found by its id when the control plane did not say.
        if !relays.is_empty() {
            builder = builder.address_lookup(iroh_mainline_address_lookup::DhtAddressLookup::builder().no_publish());
        }
        let endpoint = builder.bind().await.map_err(err)?;
        let id = hex::encode(endpoint.id().as_bytes());
        let carriers = relay.map(|queues| carry::Carriers::start(queues, key));
        Ok(Answer::json(json!({ "id": self.keep(Handle::Endpoint(Arc::new(Bound { endpoint, carriers }))), "endpoint": id })))
    }

    fn answer(&self, id: u64, done: Done) {
        let (json, error, bytes) = match done {
            Ok(answer) => (serde_json::to_vec(&answer.json).unwrap_or_default(), Vec::new(), answer.bytes),
            Err(e) => (Vec::new(), if e.is_empty() { b"failed".to_vec() } else { e.into_bytes() }, None),
        };
        let (b, blen, has) = match &bytes {
            Some(b) => (b.as_ptr(), b.len(), 1),
            None => (std::ptr::null(), 0, 0),
        };
        (self.complete)(self.ctx.0, id, json.as_ptr(), json.len(), error.as_ptr(), error.len(), b, blen, has);
    }
}

impl Mesh {
    pub fn start(complete: Complete, ctx: *mut c_void) -> std::io::Result<Mesh> {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("comma-mesh").enable_all().build()?;
        let inner = Arc::new(Inner { complete, ctx: Ctx(ctx), handles: Mutex::default(), next: AtomicU64::new(1), running: Mutex::default() });
        Ok(Mesh { runtime, inner })
    }

    /// Starts operation `id`. A panic in it fails it; given up (`abort`), it is never answered.
    pub fn call(&self, id: u64, op: String, json: &[u8], bytes: Option<Vec<u8>>) {
        let inner = self.inner.clone();
        let args: Value = serde_json::from_slice(json).unwrap_or(Value::Null);
        // Held while the work is spawned and recorded, so the work's end, which forgets it, comes after.
        let mut running = self.inner.running.lock().unwrap();
        let work = {
            let inner = inner.clone();
            self.runtime.spawn(async move { inner.run(&op, args, bytes).await })
        };
        running.insert(id, work.abort_handle());
        self.runtime.spawn(async move {
            let done = match work.await {
                Ok(done) => done,
                Err(e) if e.is_panic() => Err("the mesh failed".to_string()),
                Err(_) => {
                    inner.running.lock().unwrap().remove(&id);
                    return;
                }
            };
            inner.running.lock().unwrap().remove(&id);
            inner.answer(id, done);
        });
    }

    pub fn abort(&self, id: u64) {
        if let Some(work) = self.inner.running.lock().unwrap().remove(&id) {
            work.abort();
        }
    }
}

/// Starts the mesh. Null when it cannot (no threads for it).
///
/// # Safety
/// `complete` may be called with `ctx` from any thread until `comma_mesh_stop`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn comma_mesh_start(complete: Complete, ctx: *mut c_void) -> *mut Mesh {
    match Mesh::start(complete, ctx) {
        Ok(mesh) => Box::into_raw(Box::new(mesh)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Starts operation `id`.
///
/// # Safety
/// `mesh` is from `comma_mesh_start`; `op` NUL-terminated; `json`/`bytes` valid for their lengths (`bytes` read only
/// when `has_bytes`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn comma_mesh_call(mesh: *const Mesh, id: u64, op: *const c_char, json: *const u8, json_len: usize, bytes: *const u8, bytes_len: usize, has_bytes: u8) {
    // SAFETY: as documented.
    let (mesh, op, json) = unsafe { (&*mesh, CStr::from_ptr(op).to_string_lossy().into_owned(), std::slice::from_raw_parts(json, json_len)) };
    let bytes = (has_bytes != 0).then(|| if bytes_len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(bytes, bytes_len) }.to_vec() });
    mesh.call(id, op, json, bytes);
}

/// Gives operation `id` up: it is never answered.
///
/// # Safety
/// `mesh` is from `comma_mesh_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn comma_mesh_abort(mesh: *const Mesh, id: u64) {
    // SAFETY: as documented.
    unsafe { &*mesh }.abort(id);
}

/// Stops the mesh: what is under way is dropped, its answers never come.
///
/// # Safety
/// `mesh` from `comma_mesh_start`, not used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn comma_mesh_stop(mesh: *mut Mesh) {
    if !mesh.is_null() {
        // SAFETY: made by `comma_mesh_start`.
        let mesh = unsafe { Box::from_raw(mesh) };
        mesh.runtime.shutdown_background();
    }
}

#[cfg(test)]
mod tests;
