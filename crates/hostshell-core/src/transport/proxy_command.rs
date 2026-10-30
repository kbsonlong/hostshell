use std::io;
use std::pin::Pin;
use std::process::Stdio;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::error::{HostShellError, Result};
use crate::transport::stream::BoxedStream;

/// A byte-stream backed by a child process's stdin/stdout.
/// This mirrors what OpenSSH does with `ProxyCommand`: the process's stdio IS the transport.
pub struct ProcessStream {
    stdin: ChildStdin,
    stdout: ChildStdout,
    _child: Child,
}

impl AsyncRead for ProcessStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdout).poll_read(cx, buf)
    }
}

impl AsyncWrite for ProcessStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stdin).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdin).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdin).poll_shutdown(cx)
    }
}

/// Expand ProxyCommand template variables:
/// - `%h` → hostname
/// - `%p` → port
fn expand_proxy_command(template: &str, hostname: &str, port: u16) -> String {
    template
        .replace("%h", hostname)
        .replace("%p", &port.to_string())
}

/// Spawn a local ProxyCommand process and return its stdin/stdout as a `BoxedStream`.
///
/// The command template supports `%h` (hostname) and `%p` (port) substitution,
/// identical to OpenSSH's ProxyCommand behaviour.
pub async fn connect_proxy_command(
    cmd_template: &str,
    hostname: &str,
    port: u16,
) -> Result<BoxedStream> {
    let expanded = expand_proxy_command(cmd_template, hostname, port);
    tracing::debug!("Spawning ProxyCommand: {}", expanded);

    // Split into program + args using shell-style tokenisation (simple split on whitespace;
    // sufficient for the cloudflared invocation pattern).
    let mut parts = expanded.split_whitespace();
    let program = parts
        .next()
        .ok_or_else(|| HostShellError::Proxy("ProxyCommand is empty".to_string()))?;
    let args: Vec<&str> = parts.collect();

    let mut child = Command::new(program)
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit()) // let cloudflared diagnostics show on our stderr
        .spawn()
        .map_err(|e| {
            HostShellError::Proxy(format!(
                "Failed to spawn ProxyCommand '{}': {}",
                expanded, e
            ))
        })?;

    let stdin = child.stdin.take().ok_or_else(|| {
        HostShellError::Proxy("ProxyCommand process has no stdin".to_string())
    })?;
    let stdout = child.stdout.take().ok_or_else(|| {
        HostShellError::Proxy("ProxyCommand process has no stdout".to_string())
    })?;

    let stream = ProcessStream {
        stdin,
        stdout,
        _child: child,
    };

    tracing::info!("ProxyCommand '{}' spawned successfully", expanded);
    Ok(Box::pin(stream) as BoxedStream)
}
