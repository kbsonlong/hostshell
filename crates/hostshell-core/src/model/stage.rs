use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", content = "details", rename_all = "snake_case")]
pub enum ConnectionStage {
    Initializing,
    
    // Direct or proxy transport stages
    ConnectingTransport {
        target: String,
        description: String,
    },
    
    // ProxyJump Bastion stages
    BastionConnecting {
        hop: usize,
        total_hops: usize,
        bastion_name: String,
    },
    BastionAuthenticated {
        hop: usize,
        total_hops: usize,
        bastion_name: String,
    },
    BastionTunnelReady {
        hop: usize,
        total_hops: usize,
        target: String,
    },

    // Cloudflare Zero Trust stages
    CloudflareHandshaking {
        endpoint: String,
        auth_type: String,
    },
    CloudflareAuthenticated,

    // Target SSH stages
    SshHandshaking {
        target: String,
    },
    HostKeyPrompt {
        host: String,
        key_type: String,
        fingerprint: String,
    },
    AuthenticatingUser {
        username: String,
        method: String,
    },
    OpeningPty,
    Connected {
        target: String,
    },
    Disconnected {
        reason: String,
    },
    Failed {
        failed_stage: String,
        error_category: String,
        message: String,
        suggestion: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageEvent {
    pub timestamp_ms: u64,
    pub stage: ConnectionStage,
}

impl StageEvent {
    pub fn now(stage: ConnectionStage) -> Self {
        let timestamp_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        Self {
            timestamp_ms,
            stage,
        }
    }
}
