//! The client core's iroh in the browser (clients/packages/core/src/hosts/web-mesh.ts): an endpoint on the relays
//! alone (a browser has no UDP), its connections to stations and their streams, and Salix as the relay of last resort
//! (the station's salix.rs; the page's WebSocket carries the packets, as @comma/mesh's salix-relay.ts does for the
//! desktop). It answers as the station's addon does to Node (systems/station/native/mesh, @comma/mesh's
//! station-native.ts `NativeEndpoint`), so the same mesh runs over either.
//!
//! Every method that waits answers a Promise: each takes what it needs out of `self` first, as wasm-bindgen's futures
//! must own what they hold.

#[path = "../../../../../systems/station/native/mesh/src/salix.rs"]
mod salix;

use std::cell::RefCell;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::Arc;

use futures::channel::oneshot;
use futures::lock::Mutex;
use futures::Stream as _;
use iroh::endpoint::{Connection as IrohConnection, QuicTransportConfig, RecvStream, SendStream, presets::Minimal};
use iroh::{Endpoint as IrohEndpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey};
use js_sys::{Array, Object, Promise, Reflect, Uint8Array};
use serde::Deserialize;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::future_to_promise;

fn failed(error: impl std::fmt::Display) -> JsValue {
    js_sys::Error::new(&error.to_string()).into()
}

fn relay_url(url: &str) -> Result<RelayUrl, JsValue> {
    url.parse().map_err(failed)
}

fn endpoint_id(hex_id: &str) -> Result<EndpointId, JsValue> {
    let bytes: [u8; 32] = hex::decode(hex_id).map_err(failed)?.try_into().map_err(|_| failed("the id is not 32 bytes"))?;
    EndpointId::from_bytes(&bytes).map_err(failed)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Options {
    /// The device's 32-byte key.
    secret_key: Vec<u8>,
    relay_urls: Vec<String>,
    #[serde(default)]
    salix_relay: bool,
}

/// As the station's addon paces: BBR with a first window of 256 KiB, so a screen's first page crosses in one round
/// trip and a big answer keeps the relay's queue short.
fn transport() -> QuicTransportConfig {
    let mut bbr = noq_proto::congestion::Bbr3Config::default();
    bbr.initial_window(256 * 1024);
    QuicTransportConfig::builder().congestion_controller_factory(Arc::new(bbr)).build()
}

/// An endpoint with the device's key on the control plane's relays, and through Salix when `salixRelay`.
#[wasm_bindgen]
pub fn bind(options: JsValue) -> Promise {
    console_error_panic_hook::set_once();
    future_to_promise(async move {
        let options: Options = serde_wasm_bindgen::from_value(options).map_err(failed)?;
        let bytes: [u8; 32] = options.secret_key.as_slice().try_into().map_err(|_| failed("the key is not 32 bytes"))?;
        let key = SecretKey::from_bytes(&bytes);
        let relays: Vec<RelayUrl> = options.relay_urls.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
        let mut builder = IrohEndpoint::builder(Minimal)
            .secret_key(key.clone())
            .relay_mode(if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(iroh::RelayMap::from_iter(relays)) })
            .transport_config(transport());
        let mut relay = None;
        if options.salix_relay {
            let (transport, queues) = salix::transport(key.public());
            builder = builder.add_custom_transport(transport);
            relay = Some(queues);
        }
        let endpoint = builder.bind().await.map_err(failed)?;
        Ok(Endpoint { inner: endpoint, key, relay }.into())
    })
}

#[derive(Deserialize)]
struct Addr {
    id: String,
    #[serde(default)]
    relays: Option<Vec<String>>,
    #[serde(default)]
    salix: Option<bool>,
}

#[wasm_bindgen]
pub struct Endpoint {
    inner: IrohEndpoint,
    key: SecretKey,
    relay: Option<Arc<salix::Relay>>,
}

#[wasm_bindgen]
impl Endpoint {
    /// Its id (hex).
    pub fn id(&self) -> String {
        hex::encode(self.inner.id().as_bytes())
    }

    /// Where it listens: nowhere, on relays alone.
    pub fn sockets(&self) -> Array {
        Array::new()
    }

    /// A connection to a station offering `alpn`.
    pub fn connect(&self, addr: JsValue, alpn: Uint8Array) -> Promise {
        let endpoint = self.inner.clone();
        future_to_promise(async move {
            let addr: Addr = serde_wasm_bindgen::from_value(addr).map_err(failed)?;
            let id = endpoint_id(&addr.id)?;
            let mut to = EndpointAddr::new(id);
            for url in addr.relays.iter().flatten() {
                to = to.with_relay_url(relay_url(url)?);
            }
            if addr.salix.unwrap_or(false) {
                to = to.with_addrs([salix::transport_addr(&id)]);
            }
            let conn = endpoint.connect(to, &alpn.to_vec()).await.map_err(failed)?;
            Ok(Connection { inner: conn }.into())
        })
    }

    /// A browser takes no connections: it is never dialed.
    pub fn accept(&self) -> Promise {
        Promise::resolve(&JsValue::NULL)
    }

    /// The endpoint's key's signature of `message` (the proof Salix asks a socket for).
    pub fn sign(&self, message: Uint8Array) -> Uint8Array {
        Uint8Array::from(&self.key.sign(&message.to_vec()).to_bytes()[..])
    }

    /// A packet that came through Salix from the endpoint `from` (hex).
    #[wasm_bindgen(js_name = relayIncoming)]
    pub fn relay_incoming(&self, from: String, data: Uint8Array) -> Result<(), JsValue> {
        let relay = self.relay.as_ref().ok_or_else(|| failed("bound without the Salix relay"))?;
        relay.incoming(endpoint_id(&from)?, data.to_vec());
        Ok(())
    }

    /// The packets to send through Salix: at least one (it waits for one), at most `max`; none once closed.
    #[wasm_bindgen(js_name = relayOutgoing)]
    pub fn relay_outgoing(&self, max: u32) -> Promise {
        let relay = self.relay.clone();
        future_to_promise(async move {
            let relay = relay.ok_or_else(|| failed("bound without the Salix relay"))?;
            let out = Array::new();
            for (to, data) in relay.outgoing(max.max(1) as usize).await {
                let packet = Object::new();
                Reflect::set(&packet, &"to".into(), &hex::encode(to.as_bytes()).into())?;
                Reflect::set(&packet, &"data".into(), &Uint8Array::from(&data[..]))?;
                out.push(&packet);
            }
            Ok(out.into())
        })
    }

    pub fn close(&self) -> Promise {
        let endpoint = self.inner.clone();
        let relay = self.relay.clone();
        future_to_promise(async move {
            if let Some(relay) = relay {
                relay.close();
            }
            endpoint.close().await;
            Ok(JsValue::UNDEFINED)
        })
    }
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

#[wasm_bindgen]
pub struct Connection {
    inner: IrohConnection,
}

#[wasm_bindgen]
impl Connection {
    #[wasm_bindgen(js_name = remoteId)]
    pub fn remote_id(&self) -> String {
        hex::encode(self.inner.remote_id().as_bytes())
    }

    /// The next stream the other end opened; null once the connection is gone.
    #[wasm_bindgen(js_name = acceptBi)]
    pub fn accept_bi(&self) -> Promise {
        let conn = self.inner.clone();
        future_to_promise(async move {
            Ok(match conn.accept_bi().await {
                Ok((send, recv)) => Stream::new(send, recv).into(),
                Err(_) => JsValue::NULL,
            })
        })
    }

    #[wasm_bindgen(js_name = openBi)]
    pub fn open_bi(&self) -> Promise {
        let conn = self.inner.clone();
        future_to_promise(async move {
            let (send, recv) = conn.open_bi().await.map_err(failed)?;
            Ok(Stream::new(send, recv).into())
        })
    }

    pub fn close(&self, code: u32, reason: String) {
        self.inner.close(code.into(), reason.as_bytes());
    }

    /// Resolves when it is gone, with why, in words.
    pub fn closed(&self) -> Promise {
        let conn = self.inner.clone();
        future_to_promise(async move { Ok(conn.closed().await.to_string().into()) })
    }

    /// How it runs once that is not `last`: at once when it differs already, else when it next changes; `closed` once
    /// it is gone.
    #[wasm_bindgen(js_name = nextVia)]
    pub fn next_via(&self, last: Option<String>) -> Promise {
        let conn = self.inner.clone();
        future_to_promise(async move {
            let mut paths = conn.paths_stream();
            let change = Object::new();
            loop {
                let Some(list) = std::future::poll_fn(|cx| Pin::new(&mut paths).poll_next(cx)).await else {
                    Reflect::set(&change, &"via".into(), &JsValue::NULL)?;
                    Reflect::set(&change, &"closed".into(), &JsValue::TRUE)?;
                    return Ok(change.into());
                };
                let via = list.iter().find(|p| p.is_selected()).map(|p| via_of(p.is_ip(), p.is_relay()).to_string());
                if via != last {
                    Reflect::set(&change, &"via".into(), &via.map(JsValue::from).unwrap_or(JsValue::NULL))?;
                    Reflect::set(&change, &"closed".into(), &JsValue::FALSE)?;
                    return Ok(change.into());
                }
            }
        })
    }
}

/// The halves of a stream, and the reads waiting on it: `reset` wakes them first, so the receiving half is let go.
struct Halves {
    send: Mutex<SendStream>,
    recv: Mutex<RecvStream>,
    reset: RefCell<bool>,
    waiting: RefCell<Vec<oneshot::Sender<()>>>,
}

#[wasm_bindgen]
pub struct Stream {
    halves: Rc<Halves>,
}

impl Stream {
    fn new(send: SendStream, recv: RecvStream) -> Stream {
        Stream { halves: Rc::new(Halves { send: Mutex::new(send), recv: Mutex::new(recv), reset: RefCell::new(false), waiting: RefCell::default() }) }
    }
}

#[wasm_bindgen]
impl Stream {
    /// What came next, up to 64 KiB; null at its end (or once it was reset).
    pub fn read(&self) -> Promise {
        let halves = self.halves.clone();
        future_to_promise(async move {
            if *halves.reset.borrow() {
                return Ok(JsValue::NULL);
            }
            let (woken, wake) = oneshot::channel();
            // Those of reads done are let go.
            halves.waiting.borrow_mut().retain(|w| !w.is_canceled());
            halves.waiting.borrow_mut().push(woken);
            let mut recv = halves.recv.lock().await;
            let mut buf = vec![0u8; 64 * 1024];
            let read = match futures::future::select(Box::pin(recv.read(&mut buf)), wake).await {
                futures::future::Either::Left((read, _)) => read,
                futures::future::Either::Right(_) => Ok(None),
            };
            match read {
                Ok(Some(n)) => Ok(Uint8Array::from(&buf[..n]).into()),
                Ok(None) => Ok(JsValue::NULL),
                Err(e) => Err(failed(e)),
            }
        })
    }

    pub fn write(&self, bytes: Uint8Array) -> Promise {
        let halves = self.halves.clone();
        future_to_promise(async move {
            halves.send.lock().await.write_all(&bytes.to_vec()).await.map_err(failed)?;
            Ok(JsValue::UNDEFINED)
        })
    }

    pub fn finish(&self) -> Promise {
        let halves = self.halves.clone();
        future_to_promise(async move {
            halves.send.lock().await.finish().map_err(failed)?;
            Ok(JsValue::UNDEFINED)
        })
    }

    /// Ends it at once, both ways.
    pub fn reset(&self, code: u32) -> Promise {
        let halves = self.halves.clone();
        future_to_promise(async move {
            *halves.reset.borrow_mut() = true;
            for wake in halves.waiting.borrow_mut().drain(..) {
                let _ = wake.send(());
            }
            let _ = halves.send.lock().await.reset(code.into());
            let _ = halves.recv.lock().await.stop(code.into());
            Ok(JsValue::UNDEFINED)
        })
    }
}
