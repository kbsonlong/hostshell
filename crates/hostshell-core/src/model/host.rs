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
    pub tags: Vec<String>,
    pub last_connected_at: Option<u64>,
    pub created_at: u64,
    pub updated_at: u64,
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
