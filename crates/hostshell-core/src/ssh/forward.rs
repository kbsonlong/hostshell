use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::task::JoinHandle;

use crate::error::{HostShellError, Result};
use crate::model::host::{ForwardEndpoint, PortForwardRule};

use super::handler::{RemoteForwardTargets, TargetClientHandler};

#[derive(Default)]
pub struct ForwardRuntime {
    tasks: Vec<JoinHandle<()>>,
    local_socket_paths: Vec<PathBuf>,
    remote_tcp: Vec<(String, u32)>,
    remote_streamlocal: Vec<String>,
    remote_targets: RemoteForwardTargets,
}

impl ForwardRuntime {
    pub async fn stop(mut self, handle: &Arc<russh::client::Handle<TargetClientHandler>>) {
        for task in self.tasks.drain(..) {
            task.abort();
        }
        for (address, port) in self.remote_tcp.drain(..) {
            let _ = handle.cancel_tcpip_forward(address, port).await;
        }
        for path in self.remote_streamlocal.drain(..) {
            let _ = handle.cancel_streamlocal_forward(path).await;
        }
        self.remote_targets.clear();
        for path in self.local_socket_paths.drain(..) {
            let _ = std::fs::remove_file(path);
        }
    }
}

impl Drop for ForwardRuntime {
    fn drop(&mut self) {
        for task in self.tasks.drain(..) { task.abort(); }
        for path in self.local_socket_paths.drain(..) { let _ = std::fs::remove_file(path); }
    }
}

pub async fn start_forwards(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    rules: &[PortForwardRule],
    remote_targets: RemoteForwardTargets,
) -> Result<ForwardRuntime> {
    let mut runtime = ForwardRuntime::default();
    runtime.remote_targets = remote_targets.clone();

    for rule in rules {
        match rule.direction.as_str() {
            "local" => start_local_forward(Arc::clone(&handle), rule, &mut runtime).await?,
            "dynamic" => start_dynamic_forward(Arc::clone(&handle), rule, &mut runtime).await?,
            "remote" => start_remote_forward(Arc::clone(&handle), rule, &mut runtime).await?,
            other => return Err(HostShellError::Config(format!("Unsupported forward direction: {other}"))),
        }
    }
    Ok(runtime)
}

async fn start_local_forward(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    rule: &PortForwardRule,
    runtime: &mut ForwardRuntime,
) -> Result<()> {
    let target = rule.target.clone().ok_or_else(|| HostShellError::Config("LocalForward requires a target".into()))?;
    match rule.bind.endpoint_type.as_str() {
        "tcp" => {
            let address = tcp_address(&rule.bind)?;
            let listener = TcpListener::bind(&address).await.map_err(|e| HostShellError::Session(format!("Cannot bind local forward {address}: {e}")))?;
            let handle = Arc::clone(&handle);
            runtime.tasks.push(tokio::spawn(async move {
                loop {
                    match listener.accept().await {
                        Ok((stream, origin)) => {
                            let handle = Arc::clone(&handle);
                            let target = target.clone();
                            tokio::spawn(async move {
                                if let Err(error) = bridge_local_tcp(handle, stream, target, origin.port()).await {
                                    tracing::warn!("LocalForward channel failed: {error}");
                                }
                            });
                        }
                        Err(error) => { tracing::warn!("LocalForward listener stopped: {error}"); break; }
                    }
                }
            }));
        }
        "streamlocal" => {
            let path = socket_path(&rule.bind)?;
            let listener = UnixListener::bind(&path).map_err(|e| HostShellError::Session(format!("Cannot bind local socket {}: {e}", path.display())))?;
            runtime.local_socket_paths.push(path);
            let handle = Arc::clone(&handle);
            runtime.tasks.push(tokio::spawn(async move {
                loop {
                    match listener.accept().await {
                        Ok((stream, _)) => {
                            let handle = Arc::clone(&handle);
                            let target = target.clone();
                            tokio::spawn(async move {
                                if let Err(error) = bridge_local_unix(handle, stream, target).await {
                                    tracing::warn!("Local streamlocal forward failed: {error}");
                                }
                            });
                        }
                        Err(error) => { tracing::warn!("Local socket forward stopped: {error}"); break; }
                    }
                }
            }));
        }
        other => return Err(HostShellError::Config(format!("Unsupported local bind endpoint: {other}"))),
    }
    Ok(())
}

async fn start_dynamic_forward(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    rule: &PortForwardRule,
    runtime: &mut ForwardRuntime,
) -> Result<()> {
    let address = tcp_address(&rule.bind)?;
    let listener = TcpListener::bind(&address).await.map_err(|e| HostShellError::Session(format!("Cannot bind SOCKS5 listener {address}: {e}")))?;
    let handle = Arc::clone(&handle);
    runtime.tasks.push(tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, origin)) => {
                    let handle = Arc::clone(&handle);
                    tokio::spawn(async move {
                        if let Err(error) = handle_socks5(handle, stream, origin.port()).await {
                            tracing::debug!("SOCKS5 connection closed: {error}");
                        }
                    });
                }
                Err(error) => { tracing::warn!("SOCKS5 listener stopped: {error}"); break; }
            }
        }
    }));
    Ok(())
}

async fn start_remote_forward(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    rule: &PortForwardRule,
    runtime: &mut ForwardRuntime,
) -> Result<()> {
    let target = rule.target.clone().ok_or_else(|| HostShellError::Config("RemoteForward requires a target".into()))?;
    match rule.bind.endpoint_type.as_str() {
        "tcp" => {
            let address = rule.bind.address.as_deref().unwrap_or("127.0.0.1");
            let port = rule.bind.port.ok_or_else(|| HostShellError::Config("RemoteForward TCP bind is missing port".into()))?;
            let actual_port = handle.tcpip_forward(address, u32::from(port)).await.map_err(|e| HostShellError::Session(format!("Remote TCP forward {address}:{port} failed: {e}")))?;
            runtime.remote_tcp.push((address.to_string(), actual_port));
            runtime.remote_targets.add_tcp(actual_port, target);
        }
        "streamlocal" => {
            let path = socket_path(&rule.bind)?;
            let path_string = path.to_string_lossy().to_string();
            handle.streamlocal_forward(path_string.clone()).await.map_err(|e| HostShellError::Session(format!("Remote Unix socket forward {path_string} failed: {e}")))?;
            runtime.remote_streamlocal.push(path_string.clone());
            runtime.remote_targets.add_streamlocal(path_string, target);
        }
        other => return Err(HostShellError::Config(format!("Unsupported remote bind endpoint: {other}"))),
    }
    Ok(())
}

async fn bridge_local_tcp(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    mut local: TcpStream,
    target: ForwardEndpoint,
    origin_port: u16,
) -> std::io::Result<()> {
    let channel = match target.endpoint_type.as_str() {
        "tcp" => handle.channel_open_direct_tcpip(
            target.address.unwrap_or_else(|| "127.0.0.1".into()),
            u32::from(target.port.unwrap_or_default()),
            "127.0.0.1",
            u32::from(origin_port),
        ).await.map_err(to_io_error)?,
        "streamlocal" => handle.channel_open_direct_streamlocal(target.path.unwrap_or_default()).await.map_err(to_io_error)?,
        _ => return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid forward target endpoint")),
    };
    let mut remote = channel.into_stream();
    tokio::io::copy_bidirectional(&mut local, &mut remote).await.map(|_| ())
}

async fn bridge_local_unix(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    mut local: UnixStream,
    target: ForwardEndpoint,
) -> std::io::Result<()> {
    let channel = match target.endpoint_type.as_str() {
        "tcp" => handle.channel_open_direct_tcpip(
            target.address.unwrap_or_else(|| "127.0.0.1".into()),
            u32::from(target.port.unwrap_or_default()),
            "127.0.0.1",
            0,
        ).await.map_err(to_io_error)?,
        "streamlocal" => handle.channel_open_direct_streamlocal(target.path.unwrap_or_default()).await.map_err(to_io_error)?,
        _ => return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid forward target endpoint")),
    };
    let mut remote = channel.into_stream();
    tokio::io::copy_bidirectional(&mut local, &mut remote).await.map(|_| ())
}

async fn handle_socks5(
    handle: Arc<russh::client::Handle<TargetClientHandler>>,
    mut local: TcpStream,
    origin_port: u16,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut header = [0u8; 2];
    local.read_exact(&mut header).await?;
    if header[0] != 5 || header[1] == 0 { return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid SOCKS5 greeting")); }
    let mut methods = vec![0; usize::from(header[1])];
    local.read_exact(&mut methods).await?;
    if !methods.contains(&0) {
        local.write_all(&[5, 0xff]).await?;
        return Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "SOCKS5 requires unsupported authentication"));
    }
    local.write_all(&[5, 0]).await?;

    let mut request = [0u8; 4];
    local.read_exact(&mut request).await?;
    if request[0] != 5 || request[1] != 1 {
        local.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        return Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "SOCKS5 only supports CONNECT"));
    }
    let host = match request[3] {
        1 => { let mut b = [0u8; 4]; local.read_exact(&mut b).await?; std::net::Ipv4Addr::from(b).to_string() }
        4 => { let mut b = [0u8; 16]; local.read_exact(&mut b).await?; std::net::Ipv6Addr::from(b).to_string() }
        3 => { let mut n = [0u8; 1]; local.read_exact(&mut n).await?; let mut b = vec![0; usize::from(n[0])]; local.read_exact(&mut b).await?; String::from_utf8(b).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))? }
        _ => { local.write_all(&[5, 8, 0, 1, 0, 0, 0, 0, 0, 0]).await?; return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "unsupported SOCKS5 address type")); }
    };
    let mut port = [0u8; 2];
    local.read_exact(&mut port).await?;
    let port = u16::from_be_bytes(port);
    let channel = match handle.channel_open_direct_tcpip(host, u32::from(port), "127.0.0.1", u32::from(origin_port)).await {
        Ok(channel) => channel,
        Err(error) => {
            local.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            return Err(to_io_error(error));
        }
    };
    local.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    let mut remote = channel.into_stream();
    tokio::io::copy_bidirectional(&mut local, &mut remote).await.map(|_| ())
}

pub(super) async fn bridge_remote_tcp(
    channel: russh::Channel<russh::client::Msg>,
    target: ForwardEndpoint,
) -> std::io::Result<()> {
    bridge_remote(channel, target).await
}

pub(super) async fn bridge_remote_streamlocal(
    channel: russh::Channel<russh::client::Msg>,
    target: ForwardEndpoint,
) -> std::io::Result<()> {
    bridge_remote(channel, target).await
}

async fn bridge_remote(
    channel: russh::Channel<russh::client::Msg>,
    target: ForwardEndpoint,
) -> std::io::Result<()> {
    let mut remote = channel.into_stream();
    match target.endpoint_type.as_str() {
        "tcp" => {
            let address = tcp_address(&target).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e.to_string()))?;
            let mut local = TcpStream::connect(address).await?;
            tokio::io::copy_bidirectional(&mut remote, &mut local).await.map(|_| ())
        }
        "streamlocal" => {
            let path = socket_path(&target).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e.to_string()))?;
            let mut local = UnixStream::connect(path).await?;
            tokio::io::copy_bidirectional(&mut remote, &mut local).await.map(|_| ())
        }
        _ => Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid local forward target")),
    }
}

fn tcp_address(endpoint: &ForwardEndpoint) -> Result<String> {
    if endpoint.endpoint_type != "tcp" { return Err(HostShellError::Config("TCP listener requires a TCP endpoint".into())); }
    let address = endpoint.address.as_deref().unwrap_or("127.0.0.1");
    let port = endpoint.port.ok_or_else(|| HostShellError::Config("TCP endpoint is missing a port".into()))?;
    if address.contains(':') {
        Ok(format!("[{address}]:{port}"))
    } else {
        Ok(format!("{address}:{port}"))
    }
}

fn socket_path(endpoint: &ForwardEndpoint) -> Result<PathBuf> {
    if endpoint.endpoint_type != "streamlocal" { return Err(HostShellError::Config("Unix socket listener requires a streamlocal endpoint".into())); }
    endpoint.path.as_deref().map(PathBuf::from).ok_or_else(|| HostShellError::Config("Unix socket endpoint is missing a path".into()))
}

fn to_io_error(error: impl std::fmt::Display) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::ConnectionAborted, error.to_string())
}
