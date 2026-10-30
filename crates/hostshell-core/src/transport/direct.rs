use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;

use crate::error::{HostShellError, Result};
use crate::transport::stream::BoxedStream;

pub async fn connect_direct(host: &str, port: u16, timeout_duration: Duration) -> Result<BoxedStream> {
    let addr = format!("{}:{}", host, port);
    tracing::debug!("Connecting directly to TCP address {}", addr);

    let stream = timeout(timeout_duration, TcpStream::connect(&addr))
        .await
        .map_err(|_| HostShellError::Network(format!("Connection to {} timed out", addr)))?
        .map_err(|e| HostShellError::Network(format!("Failed to connect to {}: {}", addr, e)))?;

    let _ = stream.set_nodelay(true);

    Ok(Box::pin(stream) as BoxedStream)
}
