//! Comma station tools gateway: Salix calls `POST /v1/stations/:id/tools` over
//! HTTP; the gateway forwards each call to the station over iroh on ALPN
//! `comma/tools/1` and returns the station's response (contract §8, §9).

pub mod api;
pub mod config;
pub mod metrics;
pub mod station;

use std::sync::Arc;

use iroh::Endpoint;
use tokio::sync::Semaphore;

use crate::{api::AppState, config::Config, metrics::Metrics, station::Stations};

/// The shared state for both routers, around an already bound endpoint.
pub fn state(endpoint: Endpoint, config: &Config) -> AppState {
    let metrics = Arc::new(Metrics::new());
    let stations = Arc::new(Stations::new(
        endpoint,
        config.timeouts.connect,
        config.limits.max_connections,
        metrics.clone(),
    ));
    AppState {
        stations,
        metrics,
        token: config.token.as_str().into(),
        timeouts: config.timeouts,
        slots: Arc::new(Semaphore::new(config.limits.max_in_flight)),
    }
}

/// Closes idle station connections for as long as the state lives.
pub fn spawn_idle_sweeper(state: &AppState) -> tokio::task::JoinHandle<()> {
    let stations = Arc::downgrade(&state.stations);
    let idle = state.timeouts.idle;
    tokio::spawn(async move {
        let mut tick = tokio::time::interval((idle / 4).max(std::time::Duration::from_secs(1)));
        loop {
            tick.tick().await;
            let Some(stations) = stations.upgrade() else {
                return;
            };
            stations.sweep_idle(idle).await;
        }
    })
}
