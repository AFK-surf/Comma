// Test-only peer: carries the canonical Go service server over real QUIC.
use anyhow::Result;
use iroh::{Endpoint, endpoint::presets};
use tokio::{io::AsyncWriteExt, net::TcpStream};

#[tokio::main]
async fn main() -> Result<()> {
    let target = std::env::args().nth(1).unwrap();
    let endpoint = Endpoint::builder(presets::Minimal)
        .alpns(vec![b"agent-vmm/service-tunnel/1".to_vec()])
        .bind_addr("127.0.0.1:0")?
        .bind()
        .await?;
    println!("{}", serde_json::to_string(&endpoint.addr())?);
    while let Some(incoming) = endpoint.accept().await {
        let target = target.clone();
        tokio::spawn(async move {
            let connection = incoming.await.unwrap();
            let (mut send, mut receive) = connection.accept_bi().await.unwrap();
            let socket = TcpStream::connect(target).await.unwrap();
            let (mut read, mut write) = socket.into_split();
            let _ = tokio::try_join!(
                async {
                    tokio::io::copy(&mut receive, &mut write).await?;
                    write.shutdown().await
                },
                async {
                    tokio::io::copy(&mut read, &mut send).await?;
                    let _ = send.finish();
                    std::io::Result::Ok(())
                }
            );
        });
    }
    Ok(())
}
