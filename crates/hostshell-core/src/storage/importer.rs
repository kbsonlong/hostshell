use crate::model::host::{AuthMethod, CloudflareAuthType, CloudflareConfig, ForwardEndpoint, Host, JumpHost, PortForwardRule, ProxyMode};
use std::collections::HashSet;

#[derive(Debug, Clone)]
struct JumpSpec {
    name: String,
    hostname: String,
    port: u16,
    username: String,
    auth: AuthMethod,
}

fn jump_spec_from_host(host: &Host, username_override: Option<&str>) -> JumpSpec {
    JumpSpec {
        name: host.name.clone(),
        hostname: host.hostname.clone(),
        port: host.port,
        username: username_override.unwrap_or(&host.username).to_string(),
        auth: host.auth.clone(),
    }
}

fn jump_spec_from_asset(jump: &JumpHost, username_override: Option<&str>) -> JumpSpec {
    JumpSpec {
        name: jump.name.clone(),
        hostname: jump.hostname.clone(),
        port: jump.port,
        username: username_override.unwrap_or(&jump.username).to_string(),
        auth: jump.auth.clone(),
    }
}

fn resolve_stored_host_chain(
    host: &Host,
    username_override: Option<&str>,
    existing_jumps: &[JumpHost],
) -> Result<Vec<JumpSpec>, String> {
    match host.proxy_mode {
        ProxyMode::Direct => Ok(vec![jump_spec_from_host(host, username_override)]),
        ProxyMode::ProxyJump => {
            if host.jump_host_ids.is_empty() {
                return Err(host.name.clone());
            }
            let mut chain = Vec::new();
            for jump_id in &host.jump_host_ids {
                let jump = existing_jumps
                    .iter()
                    .find(|candidate| &candidate.id == jump_id)
                    .ok_or_else(|| jump_id.clone())?;
                chain.push(jump_spec_from_asset(jump, None));
            }
            chain.push(jump_spec_from_host(host, username_override));
            Ok(chain)
        }
        ProxyMode::CloudflareAccess | ProxyMode::ProxyCommand => Err(host.name.clone()),
    }
}

fn resolve_imported_host_chain(
    index: usize,
    existing_hosts: &[Host],
    imported_hosts: &[Host],
    imported_jump_refs: &[Vec<String>],
    existing_jumps: &[JumpHost],
    visiting: &mut HashSet<String>,
) -> Result<Vec<JumpSpec>, String> {
    let host = &imported_hosts[index];
    match host.proxy_mode {
        ProxyMode::Direct => Ok(vec![jump_spec_from_host(host, None)]),
        ProxyMode::ProxyJump => {
            if imported_jump_refs[index].is_empty() {
                return Err(host.name.clone());
            }
            let mut chain = Vec::new();
            for reference in &imported_jump_refs[index] {
                chain.extend(resolve_jump_reference(
                    reference,
                    existing_hosts,
                    imported_hosts,
                    imported_jump_refs,
                    existing_jumps,
                    visiting,
                )?);
            }
            chain.push(jump_spec_from_host(host, None));
            Ok(chain)
        }
        ProxyMode::CloudflareAccess | ProxyMode::ProxyCommand => Err(host.name.clone()),
    }
}

fn resolve_jump_reference(
    reference: &str,
    existing_hosts: &[Host],
    imported_hosts: &[Host],
    imported_jump_refs: &[Vec<String>],
    existing_jumps: &[JumpHost],
    visiting: &mut HashSet<String>,
) -> Result<Vec<JumpSpec>, String> {
    let (username_override, ref_name) = match reference.rsplit_once('@') {
        Some((user, name)) if !user.is_empty() => (Some(user), name),
        _ => (None, reference),
    };
    let ref_name = ref_name.trim();
    if ref_name.is_empty() {
        return Err(reference.to_string());
    }
    let key = ref_name.to_lowercase();
    if !visiting.insert(key.clone()) {
        return Err(format!("cyclic ProxyJump reference involving '{}'", ref_name));
    }

    let result = if let Some(host) = existing_hosts.iter().find(|host| {
        host.name.eq_ignore_ascii_case(ref_name)
            && host.proxy_mode != ProxyMode::CloudflareAccess
            && host.proxy_mode != ProxyMode::ProxyCommand
    }) {
        resolve_stored_host_chain(host, username_override, existing_jumps)
    } else if let Some(index) = imported_hosts.iter().position(|host| {
        host.name.eq_ignore_ascii_case(ref_name)
            && host.proxy_mode != ProxyMode::CloudflareAccess
            && host.proxy_mode != ProxyMode::ProxyCommand
    }) {
        let result = resolve_imported_host_chain(
            index,
            existing_hosts,
            imported_hosts,
            imported_jump_refs,
            existing_jumps,
            visiting,
        );
        result.map(|mut chain| {
            if let Some(user) = username_override {
                if let Some(last) = chain.last_mut() {
                    last.username = user.to_string();
                }
            }
            chain
        })
    } else if let Some(jump) = existing_jumps
        .iter()
        .find(|jump| jump.name.eq_ignore_ascii_case(ref_name))
    {
        Ok(vec![jump_spec_from_asset(jump, username_override)])
    } else {
        Err(ref_name.to_string())
    };

    visiting.remove(&key);
    result
}

fn materialize_jump_spec(
    spec: JumpSpec,
    existing_jumps: &[JumpHost],
    jump_hosts: &mut Vec<JumpHost>,
) -> String {
    let same_asset = |jump: &JumpHost| {
        jump.hostname == spec.hostname
            && jump.port == spec.port
            && jump.username == spec.username
            && jump.auth == spec.auth
    };
    if let Some(jump) = existing_jumps
        .iter()
        .find(|jump| jump.name.eq_ignore_ascii_case(&spec.name) && same_asset(jump))
    {
        return jump.id.clone();
    }
    if let Some(jump) = jump_hosts.iter().find(|jump| same_asset(jump)) {
        return jump.id.clone();
    }

    let id = uuid::Uuid::new_v4().to_string();
    let name_taken = existing_jumps
        .iter()
        .chain(jump_hosts.iter())
        .any(|jump| jump.name.eq_ignore_ascii_case(&spec.name));
    let name = if name_taken {
        format!("{}@{} ({})", spec.username, spec.name, &id[..8])
    } else {
        spec.name
    };
    jump_hosts.push(JumpHost {
        id: id.clone(),
        name,
        hostname: spec.hostname,
        port: spec.port,
        username: spec.username,
        auth: spec.auth,
    });
    id
}

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
    let mut wildcard_or_global = true;
    for (index, line) in content.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') { continue; }
        let mut parts = trimmed.split_whitespace();
        let Some(key) = parts.next() else { continue };
        let lower = key.to_ascii_lowercase();
        let unsafe_reason = if lower == "include" || lower.starts_with("include=") || lower == "match" || lower.starts_with("match=") {
            Some("Include and Match directives are not supported")
        } else if lower.starts_with("proxyjump=") || lower.starts_with("proxycommand=") || lower.starts_with("host=") {
            Some("the key=value form of Host or proxy directives is not supported")
        } else {
            if lower == "host" {
                wildcard_or_global = parts.take_while(|name| !name.starts_with('#'))
                    .any(|name| name.contains('*') || name.contains('?') || name.starts_with('!'));
            }
            if wildcard_or_global && (lower == "proxyjump" || lower == "proxycommand") {
                Some("proxy directives in global or wildcard Host blocks are not supported")
            } else {
                None
            }
        };
        if let Some(reason) = unsafe_reason {
            return ImportResult {
                hosts: Vec::new(),
                jump_hosts: Vec::new(),
                warnings: vec![format!("Line {}: {}; no hosts were imported. Resolve the configuration before retrying.", index + 1, reason)],
            };
        }
    }
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
            if name.contains('*') || name.contains('?') || name.starts_with('!') {
                warnings.push(format!("Host pattern '{}': wildcard and negated patterns are not imported as hosts.", name));
                continue;
            }
            if name.is_empty() {
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
                    current_names = parts.take_while(|name| !name.starts_with('#')).map(|s| s.to_string()).collect();
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

    // Post-process ProxyJump references into a flat JumpHost chain. A saved
    // host may itself use ProxyJump, so resolving `target -> pci-test` must
    // produce `[jump, pci-test]` rather than treating pci-test as a direct hop.
    let imported_jump_refs: Vec<Vec<String>> = hosts
        .iter()
        .map(|host| {
            if host.proxy_mode != ProxyMode::ProxyJump {
                return Vec::new();
            }
            host.jump_host_ids
                .first()
                .map(|raw| raw.split(',').map(|hop| hop.trim().to_string()).filter(|hop| !hop.is_empty()).collect())
                .unwrap_or_default()
        })
        .collect();
    let mut jump_hosts: Vec<JumpHost> = Vec::new();
    let mut resolved_host_jump_ids: Vec<Option<Vec<String>>> = vec![None; hosts.len()];

    for idx in 0..hosts.len() {
        if hosts[idx].proxy_mode != ProxyMode::ProxyJump {
            continue;
        }
        let mut resolved_ids = Vec::new();
        let mut unresolved = None;
        for hop in &imported_jump_refs[idx] {
            let mut visiting = HashSet::new();
            match resolve_jump_reference(
                hop,
                existing_hosts,
                &hosts,
                &imported_jump_refs,
                existing_jumps,
                &mut visiting,
            ) {
                Ok(chain) => {
                    resolved_ids.extend(chain.into_iter().map(|spec| {
                        materialize_jump_spec(spec, existing_jumps, &mut jump_hosts)
                    }));
                }
                Err(missing) => {
                    unresolved = Some(missing);
                    break;
                }
            }
        }
        if let Some(missing) = unresolved {
            warnings.push(format!(
                "Host '{}': ProxyJump '{}' has no matching Host block or saved jump host; left unlinked.",
                hosts[idx].name, missing
            ));
            resolved_host_jump_ids[idx] = Some(Vec::new());
        } else {
            resolved_host_jump_ids[idx] = Some(resolved_ids);
        }
    }

    for (idx, jump_ids) in resolved_host_jump_ids.into_iter().enumerate() {
        if let Some(jump_ids) = jump_ids {
            hosts[idx].jump_host_ids = jump_ids;
        }
    }

    ImportResult { hosts, jump_hosts, warnings }
}
