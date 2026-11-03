use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMethod {
    Password(String),
    PrivateKey {
        key_data: String,
        passphrase: Option<String>,
    },
    KeyRef { id: String },
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProxyMode {
    Direct,
    ProxyJump,
    CloudflareAccess,   // WSS mode: Service Token / Web SSO
    ProxyCommand,       // Spawn a local command as stdin/stdout byte stream
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloudflareAuthType {
    ServiceToken,
    WebSso,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudflareConfig {
    pub auth_type: CloudflareAuthType,
    pub client_id: Option<String>,
    pub client_secret: Option<String>,
    pub cookie: Option<String>,
    pub hostname_override: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JumpHost {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
}

/// One SSH port/socket forwarding rule imported from OpenSSH configuration.
/// `direction` is `local`, `remote`, or `dynamic`; `endpoint_type` is `tcp` or
/// `streamlocal`. A dynamic rule only uses its bind endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForwardEndpoint {
    pub endpoint_type: String,
    #[serde(default)]
    pub address: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortForwardRule {
    pub direction: String,
    pub bind: ForwardEndpoint,
    #[serde(default)]
    pub target: Option<ForwardEndpoint>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Host {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
    pub proxy_mode: ProxyMode,
    #[serde(default)]
    pub forward_agent: bool,
    #[serde(default)]
    pub forward_agent_host_ids: Vec<String>,
    #[serde(default)]
    pub forward_agent_key_ids: Vec<String>,
    pub jump_host_ids: Vec<String>,
    pub cloudflare_config: Option<CloudflareConfig>,
    /// Raw ProxyCommand template string (e.g. `/opt/homebrew/bin/cloudflared access ssh --hostname %h`)
    #[serde(default)]
    pub proxy_command: Option<String>,
    #[serde(default)]
    pub port_forwards: Option<Vec<PortForwardRule>>,
    pub tags: Vec<String>,
    pub last_connected_at: Option<u64>,
    pub created_at: u64,
    pub updated_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TerminalSessionSettings {
    pub term_type: String,
    pub keepalive_seconds: u16,
}

impl Default for TerminalSessionSettings {
    fn default() -> Self {
        Self {
            term_type: "xterm-256color".to_string(),
            keepalive_seconds: 30,
        }
    }
}

impl TerminalSessionSettings {
    pub fn normalized(mut self) -> Self {
        if !["xterm-256color", "xterm", "screen", "tmux-256color"]
            .contains(&self.term_type.as_str())
        {
            self.term_type = Self::default().term_type;
        }
        self.keepalive_seconds = if self.keepalive_seconds == 0 {
            0
        } else {
            self.keepalive_seconds.clamp(5, 120)
        };
        self
    }
}

#[cfg(test)]
mod terminal_session_settings_tests {
    use super::TerminalSessionSettings;

    #[test]
    fn normalizes_term_type_and_keepalive_bounds() {
        let settings = TerminalSessionSettings {
            term_type: "unsupported-terminal".to_string(),
            keepalive_seconds: 1,
        }
        .normalized();
        assert_eq!(settings.term_type, "xterm-256color");
        assert_eq!(settings.keepalive_seconds, 5);

        let maximum = TerminalSessionSettings {
            term_type: "screen".to_string(),
            keepalive_seconds: 250,
        }
        .normalized();
        assert_eq!(maximum.term_type, "screen");
        assert_eq!(maximum.keepalive_seconds, 120);

        let disabled = TerminalSessionSettings {
            keepalive_seconds: 0,
            ..TerminalSessionSettings::default()
        }
        .normalized();
        assert_eq!(disabled.keepalive_seconds, 0);
    }
}

impl Default for ProxyMode {
    fn default() -> Self {
        Self::Direct
    }
}

impl Default for CloudflareAuthType {
    fn default() -> Self {
        Self::ServiceToken
    }
}
