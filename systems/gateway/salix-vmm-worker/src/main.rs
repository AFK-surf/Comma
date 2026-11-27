use salix_vmm_worker::{Config, control::read_packet, run};
use tokio::signal::unix::{SignalKind, signal};
use tokio_util::sync::CancellationToken;
use tracing_subscriber::{Layer, filter::Targets, layer::SubscriberExt, util::SubscriberInitExt};

// Stdout is the control channel: logs go to stderr, which the node inherits.
fn init_logging() {
    let targets = Targets::new()
        .with_default(tracing::Level::WARN)
        .with_target("salix_vmm_worker", tracing::Level::INFO);
    let logs = tracing_subscriber::fmt::layer()
        .json()
        .with_writer(std::io::stderr)
        .with_filter(targets);
    tracing_subscriber::registry().with(logs).init();
}

#[tokio::main]
async fn main() {
    init_logging();
    let mut stdin = tokio::io::stdin();
    let config = match read_packet(&mut stdin).await {
        Ok(Some(frame)) => serde_json::from_slice::<Config>(&frame).ok(),
        _ => None,
    };
    let Some(config) = config else {
        tracing::error!("agent vmm worker configuration frame is missing or invalid");
        std::process::exit(2);
    };
    let shutdown = CancellationToken::new();
    let stop = shutdown.clone();
    tokio::spawn(async move {
        let (Ok(mut terminate), Ok(mut interrupt)) = (
            signal(SignalKind::terminate()),
            signal(SignalKind::interrupt()),
        ) else {
            return;
        };
        tokio::select! {
            _ = terminate.recv() => {}
            _ = interrupt.recv() => {}
        }
        stop.cancel();
    });
    let code = match run(config, stdin, tokio::io::stdout(), shutdown).await {
        Ok(()) => 0,
        Err(error) => {
            tracing::error!(%error, "agent vmm worker stopped");
            1
        }
    };
    // The stdin reader may still be parked in a blocking read.
    std::process::exit(code);
}
