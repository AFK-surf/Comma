//! The worker's lifetime: its public TLS listener, its private Unix socket,
//! and the stdio channel whose end is its end.

use crate::{
    connect,
    control::Control,
    gateway::Gateway,
    iroh_tunnel::Tunnels,
    local::{self, Local},
    mux::{self, MuxHandle},
    registry,
    rpc::{self, BoxRead, BoxWrite},
    status::{Code, Status},
};
use serde::Deserialize;
use std::{fs, io, os::unix::fs::PermissionsExt, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::{TcpListener, TcpStream, UnixListener},
    sync::Semaphore,
};
use tokio_rustls::TlsAcceptor;
use tokio_util::{sync::CancellationToken, task::TaskTracker};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const KEEPALIVE: Duration = Duration::from_secs(30);
/// A Host's own calls in flight on one connection.
const MAX_INBOUND_CALLS: usize = 256;
const SHUTDOWN_GRACE: Duration = Duration::from_secs(3);
const CONNECT: &str = "/agentvmm.remote.v1.RemoteControllerService/Connect";

/// The first frame Salix sends.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// This node's name in Salix's connection and session rows.
    pub instance_id: String,
    pub remote_listen: String,
    pub tls_cert_file: String,
    pub tls_key_file: String,
    /// The private Unix socket, in a directory only Salix can enter.
    pub socket: String,
    pub token: String,
    #[serde(default)]
    pub iroh_preset: Option<String>,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn tls_acceptor(config: &Config) -> io::Result<TlsAcceptor> {
    let certificates = fs::read(&config.tls_cert_file)?;
    let certificates =
        rustls_pemfile::certs(&mut certificates.as_slice()).collect::<Result<Vec<_>, _>>()?;
    let key = fs::read(&config.tls_key_file)?;
    let key = rustls_pemfile::private_key(&mut key.as_slice())?
        .ok_or_else(|| invalid("TLS private key is missing"))?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(io::Error::other)?
        .with_no_client_auth()
        .with_single_cert(certificates, key)
        .map_err(io::Error::other)?;
    tls.alpn_protocols = vec![rpc::ALPN.to_vec()];
    Ok(TlsAcceptor::from(Arc::new(tls)))
}

/// Runs until `shutdown` is cancelled or Salix closes the control channel.
pub async fn run<R, W>(
    config: Config,
    control_reader: R,
    control_writer: W,
    shutdown: CancellationToken,
) -> io::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    if config.instance_id.is_empty() || config.token.len() < 32 {
        return Err(invalid("instance_id and a token of 32 bytes are required"));
    }
    let acceptor = tls_acceptor(&config)?;
    let remote = TcpListener::bind(&config.remote_listen).await?;
    let remote_addr = remote.local_addr()?;
    let _ = fs::remove_file(&config.socket);
    let private = UnixListener::bind(&config.socket)?;
    fs::set_permissions(&config.socket, fs::Permissions::from_mode(0o600))?;

    let control = Control::start(control_reader, control_writer, shutdown.clone());
    let gateway = Gateway::new(config.instance_id.clone(), control.clone());
    let local = Arc::new(Local {
        gateway: gateway.clone(),
        tunnels: Tunnels::new(config.iroh_preset.clone()),
        token: config.token.clone(),
    });
    control.ready(&remote_addr.to_string()).await;
    tracing::info!(gateway_instance_id = config.instance_id, %remote_addr, "agent vmm worker ready");

    let connections = TaskTracker::new();
    let private_server = tokio::spawn(local::serve(private, local, shutdown.clone()));
    loop {
        tokio::select! {
            accepted = remote.accept() => {
                if let Ok((socket, _)) = accepted {
                    let (gateway, acceptor, shutdown) = (gateway.clone(), acceptor.clone(), shutdown.clone());
                    connections.spawn(serve_connection(gateway, acceptor, socket, shutdown));
                }
            }
            _ = shutdown.cancelled() => break,
        }
    }
    // Draining: no new Host is admitted, and each connection settles its end.
    gateway.drain();
    drop(remote);
    private_server.abort();
    let _ = fs::remove_file(&config.socket);
    connections.close();
    let _ = tokio::time::timeout(SHUTDOWN_GRACE, connections.wait()).await;
    Ok(())
}

async fn serve_connection(
    gateway: Arc<Gateway>,
    acceptor: TlsAcceptor,
    socket: TcpStream,
    shutdown: CancellationToken,
) {
    let _ = socket.set_nodelay(true);
    let keepalive = socket2::TcpKeepalive::new().with_time(KEEPALIVE);
    let _ = socket2::SockRef::from(&socket).set_tcp_keepalive(&keepalive);
    let Ok(Ok(tls)) = tokio::time::timeout(HANDSHAKE_TIMEOUT, acceptor.accept(socket)).await else {
        return;
    };
    if tls.get_ref().1.alpn_protocol() != Some(rpc::ALPN) {
        return;
    }
    let (mux, mut inbound) = mux::spawn(tls, yamux::Mode::Server, 64);
    let calls = Arc::new(Semaphore::new(MAX_INBOUND_CALLS));
    let streams = TaskTracker::new();
    loop {
        tokio::select! {
            stream = inbound.recv() => {
                let Some((read, write)) = stream else { break };
                // Over the bound the stream is dropped, which resets it.
                if let Ok(permit) = calls.clone().try_acquire_owned() {
                    let (gateway, mux) = (gateway.clone(), mux.clone());
                    streams.spawn(async move {
                        let _permit = permit;
                        serve_stream(gateway, mux, read, write).await;
                    });
                }
            }
            _ = shutdown.cancelled() => break,
            _ = mux.closed().cancelled() => break,
        }
    }
    mux.close();
    streams.close();
    streams.wait().await;
}

async fn serve_stream(gateway: Arc<Gateway>, mux: MuxHandle, read: BoxRead, write: BoxWrite) {
    let Ok(call) = rpc::accept(read, write).await else {
        return;
    };
    match call.header.method.as_str() {
        CONNECT => connect::serve(gateway, mux, call).await,
        path if registry::serves(path) => registry::serve(gateway, call).await,
        _ => {
            let _ = call
                .tx
                .finish(&Status::new(Code::Unimplemented, "unknown method"))
                .await;
        }
    }
}
