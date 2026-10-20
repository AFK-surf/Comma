use anyhow::{Context, Result};
use comma_station_gateway::{api, config, spawn_idle_sweeper, state, station};
use iroh::SecretKey;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

const USAGE: &str = "usage: comma-station-gateway [serve | node-id | generate-key]
  serve         run the gateway (default)
  node-id       print the node id of the configured secret key (a COMMA_STATION_GATEWAY_KEYS entry)
  generate-key  print a new secret key and its node id";

#[tokio::main]
async fn main() -> Result<()> {
    match std::env::args().nth(1).as_deref() {
        None | Some("serve") => serve().await,
        Some("node-id") => {
            let key = config::secret_key(&|name: &str| {
                std::env::var(name).ok().filter(|v| !v.trim().is_empty())
            })?;
            println!("{}", hex::encode(key.public().as_bytes()));
            Ok(())
        }
        Some("generate-key") => {
            let key = SecretKey::from_bytes(&rand::random::<[u8; 32]>());
            println!("secret_key={}", hex::encode(key.to_bytes()));
            println!("node_id={}", hex::encode(key.public().as_bytes()));
            Ok(())
        }
        Some(_) => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    }
}

async fn serve() -> Result<()> {
    tracing_subscriber::fmt()
        .json()
        .flatten_event(true)
        .with_current_span(false)
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| {
            EnvFilter::new("info,iroh=warn,iroh_mainline_address_lookup=error,mainline=off")
        }))
        .init();
    let config = config::Config::from_env()?;
    let endpoint = station::bind(
        config.secret_key.clone(),
        &config.relay_urls,
        config.dht_lookup,
    )
    .await
    .context("bind iroh endpoint")?;
    tracing::info!(node_id = %hex::encode(endpoint.id().as_bytes()), relays = config.relay_urls.len(), dht_lookup = config.dht_lookup, "iroh endpoint bound");
    let state = state(endpoint.clone(), &config);
    let _sweeper = spawn_idle_sweeper(&state);
    let api = TcpListener::bind(config.api_listen)
        .await
        .context("bind API listener")?;
    let admin = TcpListener::bind(config.admin_listen)
        .await
        .context("bind admin listener")?;
    tracing::info!(api = %config.api_listen, admin = %config.admin_listen, "listening");

    let shutdown = shutdown_signal();
    let admin_server = axum::serve(admin, api::admin_router(state.clone()));
    let api_server = axum::serve(api, api::api_router(state)).with_graceful_shutdown(shutdown);
    tokio::select! {
        result = api_server => result.context("API server")?,
        result = admin_server => result.context("admin server")?,
    }
    endpoint.close().await;
    tracing::info!("stopped");
    Ok(())
}

async fn shutdown_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("install SIGTERM handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    tracing::info!("shutting down");
}
