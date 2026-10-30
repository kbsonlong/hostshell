use thiserror::Error;

#[derive(Error, Debug)]
pub enum HostShellError {
    #[error("Network error: {0}")]
    Network(String),

    #[error("ProxyJump error: {0}")]
    Proxy(String),

    #[error("Cloudflare Access error: {0}")]
    Cloudflare(String),

    #[error("SSH handshake error: {0}")]
    SshHandshake(String),

    #[error("Host key rejected for {host}: {fingerprint}")]
    HostKeyRejected { host: String, fingerprint: String },

    #[error("Authentication failed for user {user}: {reason}")]
    AuthenticationFailed { user: String, reason: String },

    #[error("Session error: {0}")]
    Session(String),

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("Cancelled by user")]
    Cancelled,
}

pub type Result<T> = std::result::Result<T, HostShellError>;
