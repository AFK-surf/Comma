//! The sockets that carry an endpoint's packets through Salix, the relay of last resort (Comma's client relay,
//! `GET /v1/comma/station-relay`, CommaWeb.ClientRelaySocket), as @comma/mesh's salix-relay.ts carries the desktop
//! app's: one socket for each workspace, opened with a single-use ticket and registered by proving the endpoint's key
//! over Salix's challenge. Salix passes a packet only to a peer in the Group of the socket it came on, so a peer's
//! packets go on the socket that peer was last heard on, and on every socket until it is heard. While no socket
//! carries them they are dropped, as a lost path's are: QUIC sends them again, and iroh tries its other paths.
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use iroh::{EndpointId, SecretKey};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::salix::Relay;

/// A binary frame's kind: a packet, after the peer's endpoint id (32 bytes).
const FRAME: u8 = 1;
const BATCH: usize = 64;
/// Peers whose socket is remembered: the oldest is forgotten beyond this (its packets go on every socket again).
const MAX_ROUTES: usize = 4096;
/// Salix closes a socket silent for three minutes.
const PING: Duration = Duration::from_secs(60);
/// A socket not registered by then is given up.
const REGISTER: Duration = Duration::from_secs(30);

/// The peers last heard, each on its socket, the oldest first.
#[derive(Default)]
struct Routes {
    on: HashMap<EndpointId, u64>,
    order: VecDeque<EndpointId>,
}

impl Routes {
    fn heard(&mut self, peer: EndpointId, socket: u64) {
        if self.on.insert(peer, socket).is_none() {
            self.order.push_back(peer);
            if self.order.len() > MAX_ROUTES
                && let Some(oldest) = self.order.pop_front()
            {
                self.on.remove(&oldest);
            }
        }
    }

    fn forget(&mut self, socket: u64) {
        self.on.retain(|_, on| *on != socket);
        let on = &self.on;
        self.order.retain(|peer| on.contains_key(peer));
    }
}

pub struct Carriers {
    relay: Arc<Relay>,
    key: SecretKey,
    /// The registered sockets: what each sends.
    sockets: Mutex<HashMap<u64, mpsc::UnboundedSender<Vec<u8>>>>,
    routes: Mutex<Routes>,
    next: AtomicU64,
    tls: Arc<rustls::ClientConfig>,
}

/// One socket being carried: closed once it is, by either end.
pub struct Socket {
    closed: watch::Receiver<bool>,
    close: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}

impl Socket {
    pub async fn closed(&self) {
        let mut closed = self.closed.clone();
        let _ = closed.wait_for(|c| *c).await;
    }

    pub fn close(&self) {
        if let Some(close) = self.close.lock().unwrap().take() {
            let _ = close.send(());
        }
    }
}

fn tls_config() -> rustls::ClientConfig {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth()
}

fn ws_error(error: WsError) -> String {
    match error {
        WsError::Http(response) => format!("the Salix relay refused the socket ({})", response.status().as_u16()),
        error => format!("the Salix relay: {error}"),
    }
}

/// `text` as a URL's query value takes it.
fn query_value(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

impl Carriers {
    /// Carries what goes out through `relay` from now on, for the endpoint whose key is `key`.
    pub fn start(relay: Arc<Relay>, key: SecretKey) -> Arc<Carriers> {
        let carriers = Arc::new(Carriers { relay, key, sockets: Mutex::default(), routes: Mutex::default(), next: AtomicU64::new(1), tls: Arc::new(tls_config()) });
        tokio::spawn(carriers.clone().pump());
        carriers
    }

    /// No more packets go out (the endpoint closed).
    pub fn close(&self) {
        self.relay.close();
        self.sockets.lock().unwrap().clear();
    }

    async fn pump(self: Arc<Self>) {
        loop {
            let packets = self.relay.outgoing(BATCH).await;
            if packets.is_empty() {
                return;
            }
            for (to, data) in packets {
                self.send(to, &data);
            }
        }
    }

    fn send(&self, to: EndpointId, data: &[u8]) {
        let mut frame = Vec::with_capacity(33 + data.len());
        frame.push(FRAME);
        frame.extend_from_slice(to.as_bytes());
        frame.extend_from_slice(data);
        let sockets = self.sockets.lock().unwrap();
        let on = self.routes.lock().unwrap().on.get(&to).copied();
        match on.and_then(|s| sockets.get(&s)) {
            Some(socket) => {
                let _ = socket.send(frame);
            }
            None => {
                for socket in sockets.values() {
                    let _ = socket.send(frame.clone());
                }
            }
        }
    }

    fn incoming(&self, socket: u64, frame: &[u8]) {
        if frame.len() < 33 || frame[0] != FRAME {
            return;
        }
        let Ok(from) = EndpointId::from_bytes(frame[1..33].try_into().expect("32 bytes")) else { return };
        self.routes.lock().unwrap().heard(from, socket);
        self.relay.incoming(from, frame[33..].to_vec());
    }

    /// Opens a socket at `url` with `ticket` (`<id>.<secret>`) and proves the endpoint's id on it: answered once Salix
    /// registered it; failed if it closed before, or did not register within `REGISTER`.
    pub async fn carry(self: &Arc<Self>, url: &str, ticket: &str) -> Result<Arc<Socket>, String> {
        let ticket_id = ticket.split('.').next().unwrap_or_default().to_owned();
        let address = format!("{url}?ticket={}", query_value(ticket));
        let opened = tokio::time::timeout(REGISTER, async {
            let (mut socket, _) = tokio_tungstenite::connect_async_tls_with_config(address.as_str(), None, false, Some(tokio_tungstenite::Connector::Rustls(self.tls.clone()))).await.map_err(ws_error)?;
            loop {
                let Some(message) = socket.next().await else { return Err("the Salix relay closed before it registered".to_string()) };
                let Message::Text(text) = message.map_err(ws_error)? else { continue };
                let said: serde_json::Value = serde_json::from_str(text.as_str()).unwrap_or_default();
                match said.get("type").and_then(serde_json::Value::as_str) {
                    Some("challenge") => {
                        let challenge = said.get("challenge").and_then(serde_json::Value::as_str).unwrap_or_default();
                        let proof = self.key.sign(format!("comma-salix-relay-v1:{ticket_id}:{challenge}").as_bytes());
                        let register = serde_json::json!({
                            "type": "register",
                            "endpoint_id": hex::encode(self.key.public().as_bytes()),
                            "signature": base64::engine::general_purpose::STANDARD.encode(proof.to_bytes()),
                        });
                        socket.send(Message::text(register.to_string())).await.map_err(ws_error)?;
                    }
                    Some("registered") => return Ok(socket),
                    _ => {}
                }
            }
        })
        .await;
        let mut socket = match opened {
            Ok(Ok(socket)) => socket,
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err("the Salix relay did not register the socket in time".into()),
        };
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (frames, mut outgoing) = mpsc::unbounded_channel::<Vec<u8>>();
        self.sockets.lock().unwrap().insert(id, frames);
        let (ended, closed) = watch::channel(false);
        let (close, mut closing) = tokio::sync::oneshot::channel::<()>();
        let carriers = self.clone();
        // One task owns the socket: reading is also what answers Salix's pings; what is to be sent goes between.
        tokio::spawn(async move {
            let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING, PING);
            loop {
                tokio::select! {
                    message = socket.next() => match message {
                        Some(Ok(Message::Binary(frame))) => carriers.incoming(id, &frame),
                        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                        Some(Ok(_)) => {}
                    },
                    frame = outgoing.recv() => match frame {
                        Some(frame) => if socket.send(Message::binary(frame)).await.is_err() { break },
                        // The endpoint closed: no more packets.
                        None => { let _ = socket.close(None).await; break }
                    },
                    _ = ping.tick() => if socket.send(Message::text("ping")).await.is_err() { break },
                    _ = &mut closing => { let _ = socket.close(None).await; break }
                }
            }
            carriers.sockets.lock().unwrap().remove(&id);
            carriers.routes.lock().unwrap().forget(id);
            let _ = ended.send(true);
        });
        Ok(Arc::new(Socket { closed, close: Mutex::new(Some(close)) }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer(n: u8) -> EndpointId {
        SecretKey::from_bytes(&[n; 32]).public()
    }

    #[test]
    fn a_peer_is_answered_on_the_socket_it_was_last_heard_on_until_that_one_goes() {
        let mut routes = Routes::default();
        routes.heard(peer(1), 7);
        routes.heard(peer(1), 8);
        assert_eq!(routes.on.get(&peer(1)), Some(&8));
        routes.heard(peer(2), 7);
        routes.forget(8);
        assert_eq!(routes.on.get(&peer(1)), None);
        assert_eq!(routes.on.get(&peer(2)), Some(&7));
        assert_eq!(routes.order.len(), 1);
    }

    #[test]
    fn the_oldest_peer_is_forgotten_beyond_the_routes_kept() {
        let mut routes = Routes::default();
        for n in 0..=MAX_ROUTES {
            let mut bytes = [0u8; 32];
            bytes[..8].copy_from_slice(&(n as u64).to_le_bytes());
            routes.heard(SecretKey::from_bytes(&bytes).public(), 1);
        }
        assert_eq!(routes.on.len(), MAX_ROUTES);
        assert_eq!(routes.order.len(), MAX_ROUTES);
    }
}
