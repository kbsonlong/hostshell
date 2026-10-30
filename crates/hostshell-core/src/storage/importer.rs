use crate::model::host::{AuthMethod, CloudflareAuthType, CloudflareConfig, Host, ProxyMode};

fn expand_tilde(path: &str) -> String {
    if path.starts_with('~') {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{}{}", home, &path[1..]);
        }
    }
    path.to_string()
}

#[derive(Debug, Clone)]
pub struct ImportResult {
    pub hosts: Vec<Host>,
    pub warnings: Vec<String>,
}

pub fn parse_ssh_config(content: &str) -> ImportResult {
    let mut hosts = Vec::new();
    let mut warnings = Vec::new();

    let mut current_names: Vec<String> = Vec::new();
    let mut hostname = String::new();
    let mut port: u16 = 22;
    let mut username = String::new();
    let mut identity_file: Option<String> = None;
    let mut proxy_jump: Option<String> = None;
    let mut proxy_command: Option<String> = None;

    let flush_host = |hosts: &mut Vec<Host>,
                      warnings: &mut Vec<String>,
                      names: &[String],
                      h_name: &str,
                      p: u16,
                      user: &str,
                      id_file: Option<&str>,
                      p_jump: Option<&str>,
                      p_cmd: Option<&str>| {
        for name in names {
            if name == "*" || name.contains('?') || name.is_empty() {
                continue;
            }

            let effective_host = if h_name.is_empty() { name.clone() } else { h_name.to_string() };
            let effective_user = if user.is_empty() { "root".to_string() } else { user.to_string() };

            let auth = if let Some(path) = id_file {
                let expanded_path = expand_tilde(path);
                match std::fs::read_to_string(&expanded_path) {
                    Ok(key_content) => AuthMethod::PrivateKey {
                        key_data: key_content,
                        passphrase: None,
                    },
                    Err(e) => {
                        warnings.push(format!(
                            "Host '{}': could not read IdentityFile '{}': {}. Falling back to password auth.",
                            name, expanded_path, e
                        ));
                        AuthMethod::Password(String::new())
                    }
                }
            } else {
                AuthMethod::Password(String::new())
            };

            let mut proxy_mode = ProxyMode::Direct;
            let mut jump_host_ids = Vec::new();
            let mut cf_config = None;
            let mut stored_proxy_command: Option<String> = None;

            if let Some(jump) = p_jump {
                proxy_mode = ProxyMode::ProxyJump;
                jump_host_ids.push(jump.to_string());
            } else if let Some(cmd) = p_cmd {
                // All ProxyCommand entries go through the local process-spawn path.
                proxy_mode = ProxyMode::ProxyCommand;
                stored_proxy_command = Some(cmd.to_string());

                // For cloudflared specifically, also populate CloudflareConfig stub
                // so Service Token creds can be attached later if needed.
                if cmd.contains("cloudflared") && cmd.contains("access") && cmd.contains("ssh") {
                    cf_config = Some(CloudflareConfig {
                        auth_type: CloudflareAuthType::ServiceToken,
                        client_id: None,
                        client_secret: None,
                        cookie: None,
                        hostname_override: None,
                    });
                } else {
                    // Generic ProxyCommand — just a note, no warning since we support it now.
                    tracing::debug!("Host '{}' uses generic ProxyCommand: '{}'", name, cmd);
                }
            }

            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();

            hosts.push(Host {
                id: uuid::Uuid::new_v4().to_string(),
                name: name.clone(),
                hostname: effective_host,
                port: p,
                username: effective_user,
                auth,
                proxy_mode,
                jump_host_ids,
                cloudflare_config: cf_config,
                proxy_command: stored_proxy_command,
                tags: vec!["imported".to_string()],
                last_connected_at: None,
                created_at: now,
                updated_at: now,
            });
        }
    };

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let mut parts = trimmed.split_whitespace();
        if let Some(key) = parts.next() {
            let key_lower = key.to_ascii_lowercase();
            match key_lower.as_str() {
                "host" => {
                    if !current_names.is_empty() {
                        flush_host(
                            &mut hosts,
                            &mut warnings,
                            &current_names,
                            &hostname,
                            port,
                            &username,
                            identity_file.as_deref(),
                            proxy_jump.as_deref(),
                            proxy_command.as_deref(),
                        );
                    }
                    current_names = parts.map(|s| s.to_string()).collect();
                    hostname.clear();
                    port = 22;
                    username.clear();
                    identity_file = None;
                    proxy_jump = None;
                    proxy_command = None;
                }
                "hostname" => {
                    if let Some(val) = parts.next() {
                        hostname = val.to_string();
                    }
                }
                "port" => {
                    if let Some(val) = parts.next() {
                        if let Ok(p) = val.parse::<u16>() {
                            port = p;
                        }
                    }
                }
                "user" => {
                    if let Some(val) = parts.next() {
                        username = val.to_string();
                    }
                }
                "identityfile" => {
                    let rest = trimmed[key.len()..].trim();
                    identity_file = Some(rest.to_string());
                }
                "proxyjump" => {
                    if let Some(val) = parts.next() {
                        proxy_jump = Some(val.to_string());
                    }
                }
                "proxycommand" => {
                    let rest = trimmed[key.len()..].trim();
                    proxy_command = Some(rest.to_string());
                }
                _ => {}
            }
        }
    }

    if !current_names.is_empty() {
        flush_host(
            &mut hosts,
            &mut warnings,
            &current_names,
            &hostname,
            port,
            &username,
            identity_file.as_deref(),
            proxy_jump.as_deref(),
            proxy_command.as_deref(),
        );
    }

    ImportResult { hosts, warnings }
}
