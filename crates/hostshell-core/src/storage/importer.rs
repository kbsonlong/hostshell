use crate::model::host::{AuthMethod, CloudflareAuthType, CloudflareConfig, ForwardEndpoint, Host, JumpHost, PortForwardRule, ProxyMode};

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
    pub jump_hosts: Vec<JumpHost>,
    pub warnings: Vec<String>,
}

fn parse_forward_endpoint(value: &str, default_address: &str, local_path: bool) -> Option<ForwardEndpoint> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let looks_like_socket = value.starts_with('/')
        || value.starts_with('~')
        || value.starts_with("./")
        || (!value.contains(':') && value.parse::<u16>().is_err());
    if looks_like_socket {
        return Some(ForwardEndpoint {
            endpoint_type: "streamlocal".into(),
            address: None,
            port: None,
            path: Some(if local_path { expand_tilde(value) } else { value.to_string() }),
        });
    }

    let (address, port) = if let Some(port) = value.strip_prefix('[').and_then(|v| v.split_once("]:")) {
        (port.0.to_string(), port.1.parse::<u16>().ok()?)
    } else if let Some((address, port)) = value.rsplit_once(':') {
        if address.contains(':') && !address.starts_with('[') {
            return None;
        }
        let address = address.trim_start_matches('[').trim_end_matches(']');
        let address = if address == "*" { "0.0.0.0" } else { address };
        (address.to_string(), port.parse::<u16>().ok()?)
    } else {
        (default_address.to_string(), value.parse::<u16>().ok()?)
    };

    Some(ForwardEndpoint {
        endpoint_type: "tcp".into(),
        address: Some(if address.is_empty() { default_address.into() } else { address }),
        port: Some(port),
        path: None,
    })
}

fn parse_forward_rule(direction: &str, bind: &str, target: Option<&str>) -> Option<PortForwardRule> {
    let default_address = "127.0.0.1";
    let bind_endpoint = parse_forward_endpoint(bind, default_address, direction != "remote")?;
    let target_endpoint = match target {
        Some(value) => Some(parse_forward_endpoint(value, "127.0.0.1", direction == "remote")?),
        None => None,
    };
    if direction != "dynamic" && target_endpoint.is_none() {
        return None;
    }
    if direction == "dynamic" && bind_endpoint.endpoint_type != "tcp" {
        return None;
    }
    Some(PortForwardRule {
        direction: direction.to_string(),
        bind: bind_endpoint,
        target: target_endpoint,
    })
}

pub fn parse_ssh_config(content: &str) -> ImportResult {
    parse_ssh_config_with_existing(content, &[], &[])
}

pub fn parse_ssh_config_with_existing(content: &str, existing_hosts: &[Host], existing_jumps: &[JumpHost]) -> ImportResult {
    let mut hosts = Vec::new();
    let mut warnings = Vec::new();

    let mut current_names: Vec<String> = Vec::new();
    let mut hostname = String::new();
    let mut port: u16 = 22;
    let mut username = String::new();
    let mut identity_file: Option<String> = None;
    let mut proxy_jump: Option<String> = None;
    let mut proxy_command: Option<String> = None;
    let mut forward_agent = false;
    let mut port_forwards: Vec<PortForwardRule> = Vec::new();

    let flush_host = |hosts: &mut Vec<Host>,
                      warnings: &mut Vec<String>,
                      names: &[String],
                      h_name: &str,
                      p: u16,
                      user: &str,
                      id_file: Option<&str>,
                      p_jump: Option<&str>,
                      p_cmd: Option<&str>,
                      forward: bool,
                      forwards: &[PortForwardRule]| {
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
                            "Host '{}': could not read IdentityFile '{}': {}. Falling back to ssh-agent auth.",
                            name, expanded_path, e
                        ));
                        AuthMethod::Agent
                    }
                }
            } else {
                AuthMethod::Agent
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

            if forward {
                warnings.push(format!("Host '{}': ForwardAgent is enabled; select a saved certificate in the host settings before connecting.", name));
            }

            hosts.push(Host {
                id: uuid::Uuid::new_v4().to_string(),
                name: name.clone(),
                hostname: effective_host,
                port: p,
                username: effective_user,
                auth,
                proxy_mode,
                forward_agent: forward,
                forward_agent_host_ids: vec![],
                forward_agent_key_ids: vec![],
                jump_host_ids,
                cloudflare_config: cf_config,
                proxy_command: stored_proxy_command,
                port_forwards: Some(forwards.to_vec()),
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
                            forward_agent,
                            &port_forwards,
                        );
                    }
                    current_names = parts.map(|s| s.to_string()).collect();
                    hostname.clear();
                    port = 22;
                    username.clear();
                    identity_file = None;
                    proxy_jump = None;
                    proxy_command = None;
                    forward_agent = false;
                    port_forwards.clear();
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
                "forwardagent" => {
                    forward_agent = parts.next().is_some_and(|value| value.eq_ignore_ascii_case("yes"));
                }
                "localforward" | "remoteforward" | "dynamicforward" => {
                    let bind = parts.next();
                    let target = parts.next();
                    let direction = match key_lower.as_str() {
                        "localforward" => "local",
                        "remoteforward" => "remote",
                        _ => "dynamic",
                    };
                    match bind.and_then(|bind| {
                        let target = if direction == "dynamic" { None } else { target };
                        parse_forward_rule(direction, bind, target)
                    }) {
                        Some(rule) => port_forwards.push(rule),
                        None => warnings.push(format!(
                            "Host '{}': unsupported or malformed {} rule; it was not imported.",
                            current_names.first().map(String::as_str).unwrap_or("(unknown)"),
                            key
                        )),
                    }
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
            forward_agent,
            &port_forwards,
        );
    }

    // Post-process: ProxyJump hosts carry the raw ssh-config reference (e.g.
    // "user@jump") in jump_host_ids. Resolve it against hosts from this batch,
    // materialise a JumpHost asset per referenced name (dedup by name), and
    // link the host to it by real UUID.
    let mut jump_hosts: Vec<JumpHost> = Vec::new();
    for idx in 0..hosts.len() {
        if hosts[idx].proxy_mode != ProxyMode::ProxyJump {
            continue;
        }
        let Some(raw_ref) = hosts[idx].jump_host_ids.first().cloned() else {
            continue;
        };
        let (override_user, ref_name) = match raw_ref.rsplit_once('@') {
            Some((user, name)) if !user.is_empty() => (Some(user), name),
            _ => (None, raw_ref.as_str()),
        };
        let ref_name = ref_name.to_string();
        let target = hosts
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(&ref_name) && h.proxy_mode == ProxyMode::Direct)
            .map(|h| (h.hostname.clone(), h.port, h.username.clone(), h.auth.clone(), None))
            .or_else(|| existing_jumps.iter().find(|j| j.name.eq_ignore_ascii_case(&ref_name))
                .map(|j| (j.hostname.clone(), j.port, j.username.clone(), j.auth.clone(), Some(j.id.clone()))))
            .or_else(|| existing_hosts.iter().find(|h| h.name.eq_ignore_ascii_case(&ref_name) && h.proxy_mode == ProxyMode::Direct)
                .map(|h| (h.hostname.clone(), h.port, h.username.clone(), h.auth.clone(), None)));
        match target {
            Some((hostname, port, configured_user, auth, existing_id)) => {
                let username = override_user.unwrap_or(&configured_user).to_string();
                let equivalent = existing_jumps.iter().find(|j| j.name.eq_ignore_ascii_case(&ref_name) && j.hostname == hostname && j.port == port && j.username == username && j.auth == auth);
                if let Some(id) = existing_id.filter(|_| username == configured_user).or_else(|| equivalent.map(|j| j.id.clone())) {
                    hosts[idx].jump_host_ids = vec![id];
                    continue;
                }
                let id = match jump_hosts.iter().find(|j| j.username == username && j.hostname == hostname && j.port == port && j.auth == auth) {
                    Some(j) => j.id.clone(),
                    None => {
                        let id = uuid::Uuid::new_v4().to_string();
                        let name = if existing_jumps.iter().chain(jump_hosts.iter()).any(|j| j.name.eq_ignore_ascii_case(&ref_name)) {
                            format!("{}@{} ({})", username, ref_name, &id[..8])
                        } else { ref_name.clone() };
                        jump_hosts.push(JumpHost {
                            id: id.clone(),
                            name,
                            hostname,
                            port,
                            username,
                            auth,
                        });
                        id
                    }
                };
                hosts[idx].jump_host_ids = vec![id];
            }
            None => {
                warnings.push(format!(
                    "Host '{}': ProxyJump '{}' has no matching Host block or saved jump host; left unlinked.",
                    hosts[idx].name, raw_ref
                ));
                hosts[idx].jump_host_ids = Vec::new();
            }
        }
    }

    ImportResult { hosts, jump_hosts, warnings }
}
