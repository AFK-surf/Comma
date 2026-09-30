use anyhow::{Context, Result};
use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
};

const ALPN: &[u8] = b"agent-vmm/service-tunnel/1";
const MAX_ADDRESS: usize = 8192;

#[tokio::main]
async fn main() -> Result<()> {
    let socket = std::env::args().nth(1).context("socket path required")?;
    // No incoming ALPNs: this process only dials service tunnels.
    let endpoint = Endpoint::builder(presets::N0).bind().await?;
    let listener = UnixListener::bind(socket)?;
    println!("ready");
    let slots = Arc::new(Semaphore::new(64));
    loop {
        let (stream, _) = listener.accept().await?;
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let endpoint = endpoint.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _ =
                tokio::time::timeout(Duration::from_secs(3600), tunnel(stream, &endpoint)).await;
        });
    }
}

async fn tunnel(stream: UnixStream, endpoint: &Endpoint) -> Result<()> {
    let mut local = BufReader::new(stream);
    let mut address = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let available = local.fill_buf().await?;
            anyhow::ensure!(!available.is_empty(), "missing address");
            let end = available.iter().position(|b| *b == b'\n').map(|n| n + 1);
            let count = end.unwrap_or(available.len());
            anyhow::ensure!(address.len() + count <= MAX_ADDRESS, "address too large");
            address.extend_from_slice(&available[..count]);
            local.consume(count);
            if end.is_some() {
                break;
            }
        }
        anyhow::Ok(())
    })
    .await??;
    let address: EndpointAddr = serde_json::from_slice(&address)?;
    let (connection, mut send, mut receive) =
        tokio::time::timeout(Duration::from_secs(10), async {
            let connection = endpoint.connect(address, ALPN).await?;
            let (send, receive) = connection.open_bi().await?;
            anyhow::Ok((connection, send, receive))
        })
        .await??;
    local.get_mut().write_all(b"ready\n").await?;
    let (mut read, mut write) = tokio::io::split(local);
    let outgoing = async {
        tokio::io::copy(&mut read, &mut send).await?;
        send.finish()?;
        anyhow::Ok(())
    };
    let incoming = async {
        tokio::io::copy(&mut receive, &mut write).await?;
        write.shutdown().await?;
        anyhow::Ok(())
    };
    // This is a whole gRPC connection. Either transport direction ending
    // tears it down; never retain a slot waiting for a stale peer after EOF.
    let result = tokio::select! { result = outgoing => result, result = incoming => result };
    connection.close(0u32.into(), b"tunnel complete");
    result?;
    Ok(())
}
