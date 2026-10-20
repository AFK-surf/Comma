//! From mesh/station/src/keep.rs. The station on every one of still.fail's relays, not only its home one.
//!
//! A relay passes packets on only to whoever is linked to it, and iroh keeps a link only to its home relay (the
//! nearest): one it sends nothing on is let go after a minute. So a station abroad, at home on Cloudflare's relay, was
//! out of reach of a phone in mainland China, which seldom gets through to Cloudflare (2026-10-01, bft in Tokyo); the
//! phone's packets on the other relays went nowhere. iroh 1.x takes one relay transport per endpoint, so a station
//! cannot be at home on several: each relay gets a keeper instead, a small endpoint of its own on that relay alone (no
//! IP), which the station stays connected to through that relay. The connection's keep-alives (iroh's, every 5 s)
//! are the station sending on the relay, so its link there stays up, and a device dialing on any of the relays is heard
//! (the station answers on the relay it heard it on).

use std::{
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use iroh::{Endpoint, EndpointAddr, RelayMode, RelayUrl, endpoint::presets::Minimal};

/// What the station and its keepers speak: nothing, only the connection is wanted.
const ALPN: &[u8] = b"stillfail/keep/1";
/// How long a keeper may take to be on its relay, and the station to reach it there.
const SETUP: Duration = Duration::from_secs(20);
/// The longest wait before trying a relay again; a hold that lasted this long starts the waits over.
const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// Holds the station on one relay for good, starting over (with backoff) whenever the hold breaks.
pub async fn keep(endpoint: Endpoint, relay: RelayUrl) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        if let Err(error) = hold(&endpoint, &relay).await {
            eprintln!("mesh: not held on {relay}: {error:#}");
        }
        if started.elapsed() >= MAX_BACKOFF {
            backoff = Duration::from_secs(1);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

/// One hold: a keeper on the relay, the station connected to it through the relay, until that connection ends.
async fn hold(endpoint: &Endpoint, relay: &RelayUrl) -> Result<()> {
    let keeper = Endpoint::builder(Minimal)
        .clear_ip_transports()
        .relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter([relay.clone()])))
        .alpns(vec![ALPN.to_vec()]);
    let keeper = keeper
        .bind()
        .await
        .context("keeper")?;
    let held = async {
        tokio::time::timeout(SETUP, keeper.online()).await.map_err(|_| anyhow!("keeper not on the relay after {SETUP:?}"))?;
        let addr = EndpointAddr::new(keeper.id()).with_relay_url(relay.clone());
        let dialed = async { endpoint.connect(addr, ALPN).await.context("station to keeper") };
        let accepted = async {
            let incoming = keeper.accept().await.context("keeper closed")?;
            incoming.await.context("keeper accepting")
        };
        let (conn, _accepted) = tokio::time::timeout(SETUP, async { tokio::try_join!(dialed, accepted) })
            .await
            .map_err(|_| anyhow!("no connection through the relay after {SETUP:?}"))??;
        eprintln!("mesh: held on {relay}");
        let reason = conn.closed().await;
        Err::<(), _>(anyhow!("connection through the relay ended: {reason}"))
    }
    .await;
    keeper.close().await;
    held
}

