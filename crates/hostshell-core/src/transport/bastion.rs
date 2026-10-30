use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc::UnboundedSender;
use tokio::time::timeout;

use crate::error::{HostShellError, Result};
use crate::model::host::{AuthMethod, JumpHost};
use crate::model::stage::{ConnectionStage, StageEvent};
use crate::transport::direct::connect_direct;
use crate::transport::stream::BoxedStream;

#[derive(Clone)]
pub struct BastionClientHandler;

impl russh::client::Handler for BastionClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_key: &russh::keys::PublicKeyOrCertificate,
    ) -> std::result::Result<bool, Self::Error> {
        Ok(true)
    }
}

pub struct BastionStream {
    stream: russh::ChannelStream<russh::client::Msg>,
    _handles: Vec<russh::client::Handle<BastionClientHandler>>,
}

impl AsyncRead for BastionStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for BastionStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stream).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

pub async fn connect_bastion_chain(
    jump_hosts: &[JumpHost],
    target_host: &str,
    target_port: u16,
    timeout_duration: Duration,
    stage_tx: Option<&UnboundedSender<StageEvent>>,
) -> Result<BoxedStream> {
    if jump_hosts.is_empty() {
        return Err(HostShellError::Proxy(
            "ProxyJump configuration requires at least one jump host".to_string(),
        ));
    }

    let total_hops = jump_hosts.len();
    let mut current_stream: Option<BoxedStream> = None;
    let mut handles = Vec::new();

    let russh_config = Arc::new(russh::client::Config::default());

    for (i, hop) in jump_hosts.iter().enumerate() {
        let hop_num = i + 1;
        if let Some(tx) = stage_tx {
            let _ = tx.send(StageEvent::now(ConnectionStage::BastionConnecting {
                hop: hop_num,
                total_hops,
                bastion_name: hop.name.clone(),
            }));
        }

        let stream = match current_stream.take() {
            None => connect_direct(&hop.hostname, hop.port, timeout_duration).await?,
            Some(s) => s,
        };

        let mut handle = timeout(
            timeout_duration,
            russh::client::connect_stream(russh_config.clone(), stream, BastionClientHandler),
        )
        .await
        .map_err(|_| {
            HostShellError::Proxy(format!(
                "Handshake timeout on jump host {} ({}:{})",
                hop.name, hop.hostname, hop.port
            ))
        })?
        .map_err(|e| {
            HostShellError::Proxy(format!(
                "SSH handshake failed on jump host {} ({}:{}): {}",
                hop.name, hop.hostname, hop.port, e
            ))
        })?;

        let mut auth_res = match &hop.auth {
            AuthMethod::Password(pwd) => {
                handle.authenticate_password(&hop.username, pwd).await
            }
            AuthMethod::PrivateKey { key_data, passphrase } => {
                let decoded = russh::keys::decode_openssh(
                    key_data.as_bytes(),
                    passphrase.as_deref(),
                )
                .map_err(|e| {
                    HostShellError::Proxy(format!(
                        "Failed to decode private key for jump host {}: {}",
                        hop.name, e
                    ))
                })?;
                let key_with_alg = russh::keys::key::PrivateKeyWithHashAlg::new(
                    Arc::new(decoded),
                    None,
                );
                handle.authenticate_publickey(&hop.username, key_with_alg).await
            }
            AuthMethod::Agent => {
                match crate::ssh::session::authenticate_with_agent(&mut handle, &hop.username)
                    .await
                {
                    Ok(res) => Ok(res),
                    Err(reason) => {
                        return Err(HostShellError::AuthenticationFailed {
                            user: hop.username.clone(),
                            reason: format!("Jump host {}: {}", hop.name, reason),
                        });
                    }
                }
            }
        };

        // Fallback: server only offers keyboard-interactive (PAM/MFA bastions).
        if let Ok(russh::client::AuthResult::Failure { remaining_methods, .. }) = &auth_res {
            if remaining_methods.contains(&russh::MethodKind::KeyboardInteractive) {
                if let Some(tx) = stage_tx.as_ref() {
                    let _ = tx.send(StageEvent::now(ConnectionStage::AuthenticatingUser {
                        username: hop.username.clone(),
                        method: "keyboard-interactive".to_string(),
                    }));
                }
                auth_res = match
                    crate::ssh::session::authenticate_keyboard_interactive(&mut handle, &hop.username)
                        .await
                {
                    Ok(res) => Ok(res),
                    Err(reason) => {
                        return Err(HostShellError::AuthenticationFailed {
                            user: hop.username.clone(),
                            reason: format!("Jump host {}: {}", hop.name, reason),
                        });
                    }
                };
            }
        }

        match auth_res {
            Ok(russh::client::AuthResult::Success) => {
                tracing::info!("Authenticated successfully to jump host {}", hop.name);
                if let Some(tx) = stage_tx {
                    let _ = tx.send(StageEvent::now(ConnectionStage::BastionAuthenticated {
                        hop: hop_num,
                        total_hops,
                        bastion_name: hop.name.clone(),
                    }));
                }
            }
            Ok(res) => {
                return Err(HostShellError::AuthenticationFailed {
                    user: hop.username.clone(),
                    reason: format!("Jump host {} authentication rejected: {:?}", hop.name, res),
                });
            }
            Err(e) => {
                return Err(HostShellError::Proxy(format!(
                    "Authentication error on jump host {}: {}",
                    hop.name, e
                )));
            }
        }

        let (next_host, next_port) = if hop_num < total_hops {
            let next_hop = &jump_hosts[hop_num];
            (next_hop.hostname.as_str(), next_hop.port)
        } else {
            (target_host, target_port)
        };

        let channel = handle
            .channel_open_direct_tcpip(next_host, next_port as u32, "127.0.0.1", 0)
            .await
            .map_err(|e| {
                HostShellError::Proxy(format!(
                    "Failed to open direct-tcpip tunnel through {} to {}:{}: {}",
                    hop.name, next_host, next_port, e
                ))
            })?;

        if let Some(tx) = stage_tx {
            let _ = tx.send(StageEvent::now(ConnectionStage::BastionTunnelReady {
                hop: hop_num,
                total_hops,
                target: format!("{}:{}", next_host, next_port),
            }));
        }

        handles.push(handle);
        let channel_stream = channel.into_stream();

        if hop_num < total_hops {
            current_stream = Some(Box::pin(channel_stream) as BoxedStream);
        } else {
            let bastion_stream = BastionStream {
                stream: channel_stream,
                _handles: handles,
            };
            return Ok(Box::pin(bastion_stream) as BoxedStream);
        }
    }

    Err(HostShellError::Proxy("Unexpected end of bastion chain".to_string()))
}
