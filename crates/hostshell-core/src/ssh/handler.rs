use std::sync::{Arc, Mutex};
use std::collections::HashMap;

use crate::model::host::ForwardEndpoint;
use crate::model::known_host::{KnownHostEntry, KnownHostsStore};
use crate::model::stage::{ConnectionStage, StageEvent};

#[derive(Clone)]
pub struct TargetClientHandler {
    pub hostname: String,
    pub port: u16,
    pub known_hosts: Arc<Mutex<KnownHostsStore>>,
    pub host_key_rejection: Arc<Mutex<Option<String>>>,
    pub stage_tx: Option<tokio::sync::mpsc::UnboundedSender<StageEvent>>,
    pub auto_accept_new_keys: bool,
    pub(crate) agent: Option<super::agent::AppAgent>,
    pub remote_forwards: RemoteForwardTargets,
}

#[derive(Clone, Default)]
pub struct RemoteForwardTargets {
    tcp: Arc<Mutex<HashMap<u32, ForwardEndpoint>>>,
    streamlocal: Arc<Mutex<HashMap<String, ForwardEndpoint>>>,
}

impl RemoteForwardTargets {
    pub fn add_tcp(&self, port: u32, target: ForwardEndpoint) {
        self.tcp.lock().unwrap().insert(port, target);
    }

    pub fn add_streamlocal(&self, path: String, target: ForwardEndpoint) {
        self.streamlocal.lock().unwrap().insert(path, target);
    }

    fn tcp_target(&self, port: u32) -> Option<ForwardEndpoint> {
        self.tcp.lock().unwrap().get(&port).cloned()
    }

    fn streamlocal_target(&self, path: &str) -> Option<ForwardEndpoint> {
        self.streamlocal.lock().unwrap().get(path).cloned()
    }

    pub fn clear(&self) {
        self.tcp.lock().unwrap().clear();
        self.streamlocal.lock().unwrap().clear();
    }
}

impl russh::client::Handler for TargetClientHandler {
    type Error = russh::Error;

    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: russh::client::ChannelOpenHandle,
        _session: &mut russh::client::Session,
    ) -> std::result::Result<(), Self::Error> {
        let Some(target) = self.remote_forwards.tcp_target(connected_port) else { return Ok(()); };
        reply.accept().await;
        tokio::spawn(async move {
            if let Err(error) = super::forward::bridge_remote_tcp(channel, target).await {
                tracing::debug!("RemoteForward TCP channel closed: {error}");
            }
        });
        Ok(())
    }

    async fn server_channel_open_forwarded_streamlocal(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        socket_path: &str,
        reply: russh::client::ChannelOpenHandle,
        _session: &mut russh::client::Session,
    ) -> std::result::Result<(), Self::Error> {
        let Some(target) = self.remote_forwards.streamlocal_target(socket_path) else { return Ok(()); };
        reply.accept().await;
        tokio::spawn(async move {
            if let Err(error) = super::forward::bridge_remote_streamlocal(channel, target).await {
                tracing::debug!("RemoteForward Unix socket channel closed: {error}");
            }
        });
        Ok(())
    }

    async fn server_channel_open_agent_forward(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        reply: russh::client::ChannelOpenHandle,
        _session: &mut russh::client::Session,
    ) -> std::result::Result<(), Self::Error> {
        let Some(agent) = &self.agent else { return Ok(()); };
        match agent.open() {
            Ok(mut agent) => {
                reply.accept().await;
                tokio::spawn(async move {
                    let mut stream = channel.into_stream();
                    if let Err(error) = tokio::io::copy_bidirectional(&mut stream, &mut agent).await {
                        tracing::warn!("SSH agent forwarding channel closed: {error}");
                    }
                });
            }
            Err(error) => tracing::warn!("Cannot connect to forwarded SSH agent: {error}"),
        }
        Ok(())
    }

    async fn check_server_key(
        &mut self,
        server_key: &russh::keys::PublicKeyOrCertificate,
    ) -> std::result::Result<bool, Self::Error> {
        let public_key = server_key.public_key();
        let fingerprint = public_key
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();
        let key_type = public_key.algorithm().to_string();
        let openssh_str = public_key.to_openssh().unwrap_or_default();

        let mut store = self.known_hosts.lock().unwrap();

        if let Some(existing) = store.find(&self.hostname, self.port) {
            if existing.fingerprint == fingerprint {
                tracing::info!(
                    "Host key verified for {}:{} ({})",
                    self.hostname, self.port, fingerprint
                );
                return Ok(true);
            } else {
                tracing::error!(
                    "HOST KEY MISMATCH for {}:{}! Stored: {}, Received: {}",
                    self.hostname, self.port, existing.fingerprint, fingerprint
                );
                if let Some(ref tx) = self.stage_tx {
                    let _ = tx.send(StageEvent::now(ConnectionStage::Failed {
                        failed_stage: "HostKeyVerifying".to_string(),
                        error_category: "HostKeyMismatch".to_string(),
                        message: format!(
                            "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for {}:{}! Possible MITM attack.",
                            self.hostname, self.port
                        ),
                        suggestion: "Check server fingerprint or update known_hosts if the server was legitimately reinstalled.".to_string(),
                    }));
                }
                *self.host_key_rejection.lock().unwrap() = Some(fingerprint);
                return Ok(false);
            }
        }

        // Host not in known_hosts
        if let Some(ref tx) = self.stage_tx {
            let _ = tx.send(StageEvent::now(ConnectionStage::HostKeyPrompt {
                host: format!("{}:{}", self.hostname, self.port),
                key_type: key_type.clone(),
                fingerprint: fingerprint.clone(),
            }));
        }

        if self.auto_accept_new_keys {
            let entry = KnownHostEntry {
                hostname: self.hostname.clone(),
                port: self.port,
                key_type,
                fingerprint,
                raw_public_key: openssh_str,
                added_at: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs(),
            };
            store.add(entry);
            Ok(true)
        } else {
            *self.host_key_rejection.lock().unwrap() = Some(fingerprint);
            if let Some(ref tx) = self.stage_tx {
                let _ = tx.send(StageEvent::now(ConnectionStage::Failed {
                    failed_stage: "HostKeyVerifying".to_string(),
                    error_category: "HostKeyUntrusted".to_string(),
                    message: format!("Host key for {}:{} is not trusted; connection refused.", self.hostname, self.port),
                    suggestion: "Verify the fingerprint, then enable first-use trust and reconnect.".to_string(),
                }));
            }
            Ok(false)
        }
    }
}
