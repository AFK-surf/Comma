//! Salix as the relay of last resort (systems/station/README.md): an iroh custom transport whose packets travel over
//! the WebSocket the station already holds to Salix. Its address is the peer's endpoint id under one transport id;
//! Salix forwards a packet to the station or client with that id. The packets are iroh's QUIC, encrypted end to end:
//! Salix sees only the ids. The TypeScript carries them: it takes what goes out (`relay_outgoing`) and gives what
//! came in (`relay_incoming`). Either queue full drops the packet, as a lossy path does; QUIC sends it again.
use std::io;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use iroh::endpoint::transports::{CustomEndpoint, CustomSender, CustomTransport, RecvInfo, Transmit};
use iroh::{EndpointId, TransportAddr};
use iroh_base::CustomAddr;
use tokio::sync::mpsc;

/// The transport id of packets through Salix (a private id: not in iroh's registry).
pub const SALIX_TRANSPORT_ID: u64 = 0x5a11_0001;
const QUEUE: usize = 1024;

pub fn custom_addr(id: &EndpointId) -> CustomAddr {
    CustomAddr::from_parts(SALIX_TRANSPORT_ID, id.as_bytes())
}

pub fn transport_addr(id: &EndpointId) -> TransportAddr {
    TransportAddr::Custom(custom_addr(id))
}

fn peer_of(addr: &CustomAddr) -> io::Result<EndpointId> {
    if addr.id() != SALIX_TRANSPORT_ID {
        return Err(io::Error::other("not a Salix relay address"));
    }
    let bytes: &[u8; 32] = addr.data().try_into().map_err(|_| io::Error::other("a Salix relay address is 32 bytes"))?;
    EndpointId::from_bytes(bytes).map_err(|_| io::Error::other("not an endpoint id"))
}

/// The two queues between iroh and the TypeScript.
#[derive(Debug)]
pub struct Relay {
    incoming: mpsc::Sender<(EndpointId, Vec<u8>)>,
    outgoing: tokio::sync::Mutex<mpsc::Receiver<(EndpointId, Vec<u8>)>>,
    /// Set when the endpoint closes: a wait for packets to send ends with none.
    closed: tokio::sync::watch::Sender<bool>,
}

impl Relay {
    /// A packet that came from `from` through Salix.
    pub fn incoming(&self, from: EndpointId, data: Vec<u8>) {
        let _ = self.incoming.try_send((from, data));
    }

    /// The packets to send through Salix, at least one (waiting for it), at most `max`; none once closed.
    pub async fn outgoing(&self, max: usize) -> Vec<(EndpointId, Vec<u8>)> {
        let mut closed = self.closed.subscribe();
        if *closed.borrow() {
            return Vec::new();
        }
        let mut rx = self.outgoing.lock().await;
        let mut out = Vec::new();
        tokio::select! {
            _ = rx.recv_many(&mut out, max) => {}
            _ = closed.wait_for(|c| *c) => {}
        }
        out
    }

    /// No more packets go out: every wait for them ends, and every later one ends at once.
    pub fn close(&self) {
        // `send` stores nothing while no wait subscribes; a wait that started after would never end.
        self.closed.send_replace(true);
    }
}

#[derive(Debug, Clone)]
pub struct SalixTransport {
    me: EndpointId,
    local: n0_watcher::Watchable<Vec<CustomAddr>>,
    incoming: Arc<Mutex<Option<mpsc::Receiver<(EndpointId, Vec<u8>)>>>>,
    outgoing: mpsc::Sender<(EndpointId, Vec<u8>)>,
}

/// The transport for an endpoint with id `me`, and the queues the TypeScript works.
pub fn transport(me: EndpointId) -> (Arc<SalixTransport>, Arc<Relay>) {
    let (in_tx, in_rx) = mpsc::channel(QUEUE);
    let (out_tx, out_rx) = mpsc::channel(QUEUE);
    let transport = Arc::new(SalixTransport {
        me,
        local: n0_watcher::Watchable::new(vec![custom_addr(&me)]),
        incoming: Arc::new(Mutex::new(Some(in_rx))),
        outgoing: out_tx,
    });
    (transport, Arc::new(Relay { incoming: in_tx, outgoing: tokio::sync::Mutex::new(out_rx), closed: tokio::sync::watch::channel(false).0 }))
}

impl CustomTransport for SalixTransport {
    fn bind(&self) -> io::Result<Box<dyn CustomEndpoint>> {
        let receiver = self.incoming.lock().unwrap().take().ok_or_else(|| io::Error::other("the Salix relay is bound once"))?;
        Ok(Box::new(SalixEndpoint { me: self.me, local: self.local.clone(), incoming: receiver, outgoing: self.outgoing.clone() }))
    }
}

#[derive(Debug)]
struct SalixEndpoint {
    me: EndpointId,
    local: n0_watcher::Watchable<Vec<CustomAddr>>,
    incoming: mpsc::Receiver<(EndpointId, Vec<u8>)>,
    outgoing: mpsc::Sender<(EndpointId, Vec<u8>)>,
}

#[derive(Debug)]
struct SalixSender {
    outgoing: mpsc::Sender<(EndpointId, Vec<u8>)>,
}

impl CustomSender for SalixSender {
    fn is_valid_send_addr(&self, addr: &CustomAddr) -> bool {
        addr.id() == SALIX_TRANSPORT_ID
    }

    fn poll_send(&self, _cx: &mut Context, dst: &CustomAddr, _src: Option<&CustomAddr>, transmit: &Transmit<'_>) -> Poll<io::Result<()>> {
        let to = match peer_of(dst) {
            Ok(to) => to,
            Err(e) => return Poll::Ready(Err(e)),
        };
        let size = transmit.segment_size.unwrap_or(transmit.contents.len()).max(1);
        for datagram in transmit.contents.chunks(size) {
            // A full queue drops the datagram: Salix is a lossy path, and QUIC sends it again.
            if let Err(mpsc::error::TrySendError::Closed(_)) = self.outgoing.try_send((to, datagram.to_vec())) {
                return Poll::Ready(Err(io::Error::other("the Salix relay is closed")));
            }
        }
        Poll::Ready(Ok(()))
    }
}

impl CustomEndpoint for SalixEndpoint {
    fn watch_local_addrs(&self) -> n0_watcher::Direct<Vec<CustomAddr>> {
        self.local.watch()
    }

    fn create_sender(&self) -> Arc<dyn CustomSender> {
        Arc::new(SalixSender { outgoing: self.outgoing.clone() })
    }

    fn poll_recv(&mut self, cx: &mut Context, bufs: &mut [io::IoSliceMut<'_>], metas: &mut [noq_udp::RecvMeta], recv_infos: &mut [RecvInfo]) -> Poll<io::Result<usize>> {
        let n = bufs.len();
        if n == 0 {
            return Poll::Ready(Ok(0));
        }
        let mut packets = Vec::with_capacity(n);
        match self.incoming.poll_recv_many(cx, &mut packets, n) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(0) => return Poll::Ready(Err(io::Error::other("the Salix relay is closed"))),
            Poll::Ready(_) => {}
        }
        let mut count = 0;
        for (from, data) in packets {
            let i = count;
            if bufs[i].len() < data.len() {
                continue;
            }
            bufs[i][..data.len()].copy_from_slice(&data);
            recv_infos[i] = RecvInfo::new(custom_addr(&from), Some(custom_addr(&self.me)));
            metas[i].len = data.len();
            metas[i].stride = data.len();
            count += 1;
        }
        if count > 0 {
            return Poll::Ready(Ok(count));
        }
        // Every packet was too large for its buffer and dropped: poll again rather than wait for a wake.
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}
