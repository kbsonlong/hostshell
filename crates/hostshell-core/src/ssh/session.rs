use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::timeout;

use crate::error::{HostShellError, Result};
use crate::model::host::{AuthMethod, Host, JumpHost, ProxyMode};
use crate::model::known_host::KnownHostsStore;
use crate::model::stage::{ConnectionStage, StageEvent};
use crate::ssh::handler::TargetClientHandler;
use crate::transport::{connect_bastion_chain, connect_cloudflare, connect_direct, connect_proxy_command, BoxedStream};

/// Load a private key from PEM or OpenSSH text.
///
/// `russh` parses PKCS#1 RSA, PKCS#8, and OpenSSH keys itself. Stored keys
/// may contain Windows newlines, which break the PEM header match.
fn load_private_key(
    key_data: &str,
    passphrase: Option<&str>,
    user: &str,
) -> Result<russh::keys::PrivateKey> {
    let key_data = key_data.replace('\r', "");
    russh::keys::decode_secret_key(&key_data, passphrase).map_err(|e| {
        HostShellError::AuthenticationFailed {
            user: user.to_string(),
            reason: format!("Failed to parse private key: {}", e),
        }
    })
}

pub enum SessionCommand {
    Write(Vec<u8>),
    Resize { cols: u32, rows: u32 },
    Close,
}

pub struct SessionHandle {
    pub cmd_tx: mpsc::UnboundedSender<SessionCommand>,
    pub output_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    pub stage_rx: mpsc::UnboundedReceiver<StageEvent>,
}

impl SessionHandle {
    pub fn send_input(&self, data: &[u8]) -> Result<()> {
        self.cmd_tx
            .send(SessionCommand::Write(data.to_vec()))
            .map_err(|_| HostShellError::Session("Session has closed".to_string()))
    }

    pub fn resize(&self, cols: u32, rows: u32) -> Result<()> {
        self.cmd_tx
            .send(SessionCommand::Resize { cols, rows })
            .map_err(|_| HostShellError::Session("Session has closed".to_string()))
    }

    pub fn close(&self) -> Result<()> {
        self.cmd_tx
            .send(SessionCommand::Close)
            .map_err(|_| HostShellError::Session("Session already closed".to_string()))
    }
}

pub struct SshSession;

impl SshSession {
    pub async fn connect(
        host: Host,
        jump_hosts: Vec<JumpHost>,
        known_hosts: Arc<Mutex<KnownHostsStore>>,
        cols: u32,
        rows: u32,
        auto_accept_new_keys: bool,
    ) -> Result<SessionHandle> {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<SessionCommand>();
        let (output_tx, output_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (stage_tx, stage_rx) = mpsc::unbounded_channel::<StageEvent>();

        let _ = stage_tx.send(StageEvent::now(ConnectionStage::Initializing));

        let connect_timeout = Duration::from_secs(15);

        // 1. Establish Transport Stream
        let transport_stream: BoxedStream = match host.proxy_mode {
            ProxyMode::Direct => {
                let _ = stage_tx.send(StageEvent::now(ConnectionStage::ConnectingTransport {
                    target: format!("{}:{}", host.hostname, host.port),
                    description: "Direct TCP connection".to_string(),
                }));
                connect_direct(&host.hostname, host.port, connect_timeout)
                    .await
                    .map_err(|e| {
                        let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                            failed_stage: "ConnectingTransport".to_string(),
                            error_category: "NetworkUnreachable".to_string(),
                            message: format!("Failed to connect to {}:{}: {}", host.hostname, host.port, e),
                            suggestion: "Verify network connection, target IP/domain and firewall rules.".to_string(),
                        }));
                        e
                    })?
            }
            ProxyMode::ProxyJump => {
                connect_bastion_chain(
                    &jump_hosts,
                    &host.hostname,
                    host.port,
                    connect_timeout,
                    Some(&stage_tx),
                )
                .await
                .map_err(|e| {
                    let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                        failed_stage: "BastionHop".to_string(),
                        error_category: "ProxyFailed".to_string(),
                        message: format!("ProxyJump bastion chain error: {}", e),
                        suggestion: "Check bastion configuration, credentials, and network reachable status.".to_string(),
                    }));
                    e
                })?
            }
            ProxyMode::ProxyCommand => {
                let cmd_template = host.proxy_command.as_deref().ok_or_else(|| {
                    HostShellError::Config("ProxyCommand mode requires a proxy_command string".to_string())
                })?;

                let _ = stage_tx.send(StageEvent::now(ConnectionStage::ConnectingTransport {
                    target: format!("{}:{}", host.hostname, host.port),
                    description: format!("ProxyCommand: {}", cmd_template),
                }));

                connect_proxy_command(cmd_template, &host.hostname, host.port)
                    .await
                    .map_err(|e| {
                        let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                            failed_stage: "ProxyCommand".to_string(),
                            error_category: "ProxyFailed".to_string(),
                            message: format!("Failed to spawn ProxyCommand: {}", e),
                            suggestion: "Check that the proxy command binary exists and is executable.".to_string(),
                        }));
                        e
                    })?
            }
            ProxyMode::CloudflareAccess => {
                let cf_config = host.cloudflare_config.as_ref().ok_or_else(|| {
                    HostShellError::Config("Cloudflare Access configuration is missing".to_string())
                })?;

                let auth_type_str = match cf_config.auth_type {
                    crate::model::host::CloudflareAuthType::ServiceToken => "ServiceToken",
                    crate::model::host::CloudflareAuthType::WebSso => "WebSso",
                };

                let _ = stage_tx.send(StageEvent::now(ConnectionStage::CloudflareHandshaking {
                    endpoint: host.hostname.clone(),
                    auth_type: auth_type_str.to_string(),
                }));

                let stream = connect_cloudflare(&host.hostname, cf_config, connect_timeout)
                    .await
                    .map_err(|e| {
                        let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                            failed_stage: "CloudflareHandshake".to_string(),
                            error_category: "CloudflareAuthFailed".to_string(),
                            message: format!("Cloudflare Access WSS handshake failed: {}", e),
                            suggestion: "Verify Service Token (Client ID / Secret) or refresh SSO login.".to_string(),
                        }));
                        e
                    })?;

                let _ = stage_tx.send(StageEvent::now(ConnectionStage::CloudflareAuthenticated));
                stream
            }
        };

        // 2. SSH Handshake
        let _ = stage_tx.send(StageEvent::now(ConnectionStage::SshHandshaking {
            target: format!("{}:{}", host.hostname, host.port),
        }));

        let russh_config = Arc::new(russh::client::Config {
            inactivity_timeout: Some(Duration::from_secs(30)),
            ..Default::default()
        });

        let handler = TargetClientHandler {
            hostname: host.hostname.clone(),
            port: host.port,
            known_hosts,
            stage_tx: Some(stage_tx.clone()),
            auto_accept_new_keys,
        };

        let mut handle = timeout(
            connect_timeout,
            russh::client::connect_stream(russh_config, transport_stream, handler),
        )
        .await
        .map_err(|_| {
            let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                failed_stage: "SshHandshaking".to_string(),
                error_category: "Timeout".to_string(),
                message: "Target SSH handshake timed out".to_string(),
                suggestion: "Check whether SSH service is listening on target port.".to_string(),
            }));
            HostShellError::SshHandshake("Target SSH handshake timed out".to_string())
        })?
        .map_err(|e| {
            let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                failed_stage: "SshHandshaking".to_string(),
                error_category: "HandshakeFailed".to_string(),
                message: format!("SSH handshake failed: {}", e),
                suggestion: "Ensure target server supports compatible SSH ciphers/kex algorithms.".to_string(),
            }));
            HostShellError::SshHandshake(e.to_string())
        })?;

        // 3. User Authentication
        let auth_desc = match &host.auth {
            AuthMethod::Password(_) => "password",
            AuthMethod::PrivateKey { .. } => "publickey",
            AuthMethod::Agent => "agent",
        };

        let _ = stage_tx.send(StageEvent::now(ConnectionStage::AuthenticatingUser {
            username: host.username.clone(),
            method: auth_desc.to_string(),
        }));

        let auth_res = match &host.auth {
            AuthMethod::Password(pwd) => handle.authenticate_password(&host.username, pwd).await,
            AuthMethod::PrivateKey { key_data, passphrase } => {
                let decoded = load_private_key(key_data, passphrase.as_deref(), &host.username)?;
                let key = Arc::new(decoded);
                // None selects legacy ssh-rsa (SHA-1), which current servers reject.
                let hash_algs: Vec<Option<russh::keys::HashAlg>> = if key.algorithm().is_rsa() {
                    match handle.best_supported_rsa_hash().await {
                        Ok(Some(alg)) => vec![alg],
                        _ => vec![
                            Some(russh::keys::HashAlg::Sha256),
                            Some(russh::keys::HashAlg::Sha512),
                        ],
                    }
                } else {
                    vec![None]
                };

                let mut auth_res = Ok(russh::client::AuthResult::Failure {
                    remaining_methods: russh::MethodSet::empty(),
                    partial_success: false,
                });
                for hash_alg in hash_algs {
                    let key_with_alg = russh::keys::key::PrivateKeyWithHashAlg::new(
                        Arc::clone(&key),
                        hash_alg,
                    );
                    auth_res = handle
                        .authenticate_publickey(&host.username, key_with_alg)
                        .await;
                    if matches!(auth_res, Ok(russh::client::AuthResult::Success)) {
                        break;
                    }
                }
                auth_res
            }
            AuthMethod::Agent => {
                return Err(HostShellError::AuthenticationFailed {
                    user: host.username.clone(),
                    reason: "SSH Agent authentication is disabled for sandbox security".to_string(),
                });
            }
        };

        match auth_res {
            Ok(russh::client::AuthResult::Success) => {
                tracing::info!("Target host authentication succeeded for user {}", host.username);
            }
            Ok(res) => {
                let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                    failed_stage: "AuthenticatingUser".to_string(),
                    error_category: "AuthRejected".to_string(),
                    message: format!("Authentication rejected for user {}: {:?}", host.username, res),
                    suggestion: "Check your username, password or private key configuration.".to_string(),
                }));
                return Err(HostShellError::AuthenticationFailed {
                    user: host.username.clone(),
                    reason: format!("Server rejected credentials: {:?}", res),
                });
            }
            Err(e) => {
                let _ = stage_tx.send(StageEvent::now(ConnectionStage::Failed {
                    failed_stage: "AuthenticatingUser".to_string(),
                    error_category: "AuthError".to_string(),
                    message: format!("Authentication error: {}", e),
                    suggestion: "Verify private key format or authentication protocol support.".to_string(),
                }));
                return Err(HostShellError::AuthenticationFailed {
                    user: host.username.clone(),
                    reason: e.to_string(),
                });
            }
        }

        // 4. Open PTY and Shell Channel
        let _ = stage_tx.send(StageEvent::now(ConnectionStage::OpeningPty));

        let mut channel = handle
            .channel_open_session()
            .await
            .map_err(|e| HostShellError::Session(format!("Failed to open session channel: {}", e)))?;

        channel
            .request_pty(false, "xterm-256color", cols, rows, 0, 0, &[])
            .await
            .map_err(|e| HostShellError::Session(format!("PTY request failed: {}", e)))?;

        channel
            .request_shell(false)
            .await
            .map_err(|e| HostShellError::Session(format!("Shell request failed: {}", e)))?;

        let _ = stage_tx.send(StageEvent::now(ConnectionStage::Connected {
            target: host.name.clone(),
        }));

        // 5. Spawn background session actor
        let stage_tx_clone = stage_tx.clone();
        tokio::spawn(async move {
            let mut keepalive_interval = tokio::time::interval(Duration::from_secs(15));
            loop {
                tokio::select! {
                    _ = keepalive_interval.tick() => {
                        let _ = handle.send_keepalive(false).await;
                    }

                    cmd = cmd_rx.recv() => {
                        match cmd {
                            Some(SessionCommand::Write(data)) => {
                                if let Err(e) = channel.data(&data[..]).await {
                                    tracing::warn!("Failed to write data to channel: {}", e);
                                    break;
                                }
                            }
                            Some(SessionCommand::Resize { cols, rows }) => {
                                if let Err(e) = channel.window_change(cols, rows, 0, 0).await {
                                    tracing::warn!("Failed to resize terminal window: {}", e);
                                }
                            }
                            Some(SessionCommand::Close) | None => {
                                let _ = channel.close().await;
                                break;
                            }
                        }
                    }

                    msg = channel.wait() => {
                        match msg {
                            Some(russh::ChannelMsg::Data { data }) => {
                                if output_tx.send(data.to_vec()).is_err() {
                                    break;
                                }
                            }
                            Some(russh::ChannelMsg::ExtendedData { data, .. }) => {
                                if output_tx.send(data.to_vec()).is_err() {
                                    break;
                                }
                            }
                            Some(russh::ChannelMsg::Eof) | Some(russh::ChannelMsg::Close) | None => {
                                let _ = stage_tx_clone.send(StageEvent::now(ConnectionStage::Disconnected {
                                    reason: "Remote session closed (EOF)".to_string(),
                                }));
                                break;
                            }
                            _ => {}
                        }
                    }
                }
            }

            let _ = channel.close().await;
            tracing::info!("Session actor terminated");
        });

        Ok(SessionHandle {
            cmd_tx,
            output_rx,
            stage_rx,
        })
    }
}
