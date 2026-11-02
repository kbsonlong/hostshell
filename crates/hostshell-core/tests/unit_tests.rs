use hostshell_core::model::host::{AuthMethod, CloudflareAuthType, Host, JumpHost, ProxyMode};
use hostshell_core::model::known_host::{KnownHostEntry, KnownHostsStore};
use hostshell_core::model::stage::{ConnectionStage, StageEvent};
use hostshell_core::storage::{parse_ssh_config, ConfigStore};

#[test]
fn test_parse_ssh_config_subset() {
    let sample_config = r#"
Host direct-server
    HostName 192.168.1.10
    Port 2222
    User admin

Host jump01
    HostName jump.corp.net
    Port 2022
    User jops

Host bastion-server
    HostName bastion.internal.net
    User ops
    ProxyJump jump01

Host cf-server
    HostName prod.internal.corp
    User dev
    ProxyCommand cloudflared access ssh --hostname %h

Host unsupported-server
    HostName legacy.box
    ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p
"#;

    let res = parse_ssh_config(sample_config);
    assert_eq!(res.hosts.len(), 5);

    // 1. Direct
    let direct = res.hosts.iter().find(|h| h.name == "direct-server").unwrap();
    assert_eq!(direct.hostname, "192.168.1.10");
    assert_eq!(direct.port, 2222);
    assert_eq!(direct.username, "admin");
    assert_eq!(direct.proxy_mode, ProxyMode::Direct);

    // 2. ProxyJump: raw ref resolved into a JumpHost asset linked by UUID
    let jump = res.hosts.iter().find(|h| h.name == "bastion-server").unwrap();
    assert_eq!(jump.hostname, "bastion.internal.net");
    assert_eq!(jump.proxy_mode, ProxyMode::ProxyJump);
    assert_eq!(res.jump_hosts.len(), 1);
    let jh = &res.jump_hosts[0];
    assert_eq!(jh.name, "jump01");
    assert_eq!(jh.hostname, "jump.corp.net");
    assert_eq!(jh.port, 2022);
    assert_eq!(jh.username, "jops");
    assert_eq!(jump.jump_host_ids, vec![jh.id.clone()]);

    // 3. cloudflared ProxyCommand → ProxyCommand mode (local process spawn)
    let cf = res.hosts.iter().find(|h| h.name == "cf-server").unwrap();
    assert_eq!(cf.proxy_mode, ProxyMode::ProxyCommand);
    assert!(cf.proxy_command.is_some());
    assert!(cf.proxy_command.as_ref().unwrap().contains("cloudflared"));
    // CloudflareConfig stub is still populated for future Service Token binding
    assert!(cf.cloudflare_config.is_some());
    assert_eq!(
        cf.cloudflare_config.as_ref().unwrap().auth_type,
        CloudflareAuthType::ServiceToken
    );

    // 4. Generic unsupported ProxyCommand → also ProxyCommand mode now (no warning)
    let unsupported = res.hosts.iter().find(|h| h.name == "unsupported-server").unwrap();
    assert_eq!(unsupported.proxy_mode, ProxyMode::ProxyCommand);
    assert!(unsupported.proxy_command.is_some());
    assert_eq!(res.warnings.len(), 0);
}

#[test]
fn test_cli_wire_auth_and_proxy_command_values() {
    assert_eq!(serde_json::to_string(&AuthMethod::Agent).unwrap(), "\"agent\"");
    assert_eq!(serde_json::to_string(&ProxyMode::ProxyCommand).unwrap(), "\"proxy_command\"");
}

#[test]
fn test_import_resolves_proxyjump_and_skips_wildcard_host() {
    let config = r#"
Host *
    User fallback

Host jump
    HostName jump.example.test
    Port 32200
    User engineer

Host 10.*
    Port 32200
    User engineer
    ProxyJump engineer@jump
"#;
    let result = parse_ssh_config(config);
    assert_eq!(result.hosts.len(), 2);
    assert_eq!(result.jump_hosts.len(), 1);
    assert_eq!(result.jump_hosts[0].name, "jump");
    let target = result.hosts.iter().find(|h| h.name == "10.*").unwrap();
    assert_eq!(target.proxy_mode, ProxyMode::ProxyJump);
    assert_eq!(target.jump_host_ids, vec![result.jump_hosts[0].id.clone()]);
}

#[test]
fn test_import_proxyjump_missing_target_is_warning_and_not_dangling() {
    let result = parse_ssh_config("Host private\n  HostName 10.1.2.3\n  ProxyJump missing\n");
    assert_eq!(result.hosts.len(), 1);
    assert!(result.jump_hosts.is_empty());
    assert!(result.hosts[0].jump_host_ids.is_empty());
    assert_eq!(result.warnings.len(), 1);
}

#[test]
fn test_import_matches_saved_jump_and_preserves_forward_agent() {
    let jump = JumpHost {
        id: "saved-jump".into(), name: "jump".into(), hostname: "jump.example".into(),
        port: 32200, username: "zengshenglong".into(), auth: AuthMethod::Agent,
    };
    let config = "Host 10.98.32.131\n User zengshenglong\n Port 32200\n ForwardAgent yes\n ProxyJump zengshenglong@jump\n";
    let result = hostshell_core::storage::importer::parse_ssh_config_with_existing(config, &[], &[jump.clone()]);
    assert_eq!(result.hosts[0].jump_host_ids, vec!["saved-jump"]);
    assert!(result.hosts[0].forward_agent);
    assert!(result.jump_hosts.is_empty());
    assert!(result.warnings.iter().any(|w| w.contains("select a saved certificate")));

    let saved_host = parse_ssh_config("Host jump\n HostName jump.example\n User zengshenglong\n Port 32200\n").hosts.remove(0);
    let from_hosts = hostshell_core::storage::importer::parse_ssh_config_with_existing(config, &[saved_host], &[]);
    assert_eq!(from_hosts.jump_hosts[0].hostname, "jump.example");
    assert_eq!(from_hosts.hosts[0].jump_host_ids, vec![from_hosts.jump_hosts[0].id.clone()]);

    let override_result = hostshell_core::storage::importer::parse_ssh_config_with_existing(
        "Host target\n ProxyJump other@jump\n", &[], &[jump],
    );
    assert_eq!(override_result.jump_hosts[0].username, "other");
    assert_ne!(override_result.jump_hosts[0].name, "jump");
    assert_eq!(override_result.hosts[0].jump_host_ids, vec![override_result.jump_hosts[0].id.clone()]);
}

#[test]
fn test_known_hosts_store() {
    let mut store = KnownHostsStore::new();
    let entry = KnownHostEntry {
        hostname: "example.com".to_string(),
        port: 22,
        key_type: "ssh-ed25519".to_string(),
        fingerprint: "SHA256:abc123xyz".to_string(),
        raw_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...".to_string(),
        added_at: 1000,
    };

    store.add(entry.clone());
    assert!(store.find("example.com", 22).is_some());
    assert_eq!(
        store.find("example.com", 22).unwrap().fingerprint,
        "SHA256:abc123xyz"
    );

    // Update with new fingerprint
    let mut updated = entry.clone();
    updated.fingerprint = "SHA256:newfingerprint".to_string();
    store.add(updated);
    assert_eq!(store.entries.len(), 1);
    assert_eq!(
        store.find("example.com", 22).unwrap().fingerprint,
        "SHA256:newfingerprint"
    );

    // Remove
    assert!(store.remove("example.com", 22));
    assert!(store.find("example.com", 22).is_none());
}

#[test]
fn test_stage_event_serialization() {
    let event = StageEvent::now(ConnectionStage::BastionConnecting {
        hop: 1,
        total_hops: 2,
        bastion_name: "bastion-gw".to_string(),
    });

    let json = serde_json::to_string(&event).unwrap();
    assert!(json.contains("bastion_connecting"));
    assert!(json.contains("bastion-gw"));

    let failed_evt = StageEvent::now(ConnectionStage::Failed {
        failed_stage: "CloudflareHandshake".to_string(),
        error_category: "CloudflareAuthFailed".to_string(),
        message: "Token rejected".to_string(),
        suggestion: "Please check credentials".to_string(),
    });
    let failed_json = serde_json::to_string(&failed_evt).unwrap();
    assert!(failed_json.contains("CloudflareAuthFailed"));
}

#[test]
fn test_config_store_crud() {
    let tmp_dir = std::env::temp_dir().join(format!("hostshell_test_{}", uuid::Uuid::new_v4()));
    let store = ConfigStore::with_dir(tmp_dir.clone()).unwrap();

    let host = Host {
        id: "host-1".to_string(),
        name: "Test Host".to_string(),
        hostname: "127.0.0.1".to_string(),
        port: 22,
        username: "tester".to_string(),
        auth: AuthMethod::Password("secret".to_string()),
        proxy_mode: ProxyMode::Direct,
        forward_agent: false,
        forward_agent_host_ids: vec![],
        forward_agent_key_ids: vec![],
        jump_host_ids: vec![],
        cloudflare_config: None,
        proxy_command: None,
        port_forwards: None,
        tags: vec!["prod".to_string()],
        last_connected_at: None,
        created_at: 100,
        updated_at: 100,
    };

    store.save_host(host.clone()).unwrap();
    let loaded = store.load_hosts().unwrap();
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].name, "Test Host");
    let mut referenced = host.clone();
    referenced.auth = AuthMethod::KeyRef { id: "key-1".into() };
    referenced.forward_agent = true;
    referenced.forward_agent_key_ids = vec!["key-1".into()];
    let json = serde_json::to_string(&referenced).unwrap();
    assert!(!json.contains("key_data"));
    let decoded: Host = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.auth, referenced.auth);
    assert_eq!(decoded.forward_agent_key_ids, vec!["key-1"]);
    let mut same_name = host.clone();
    same_name.id = "host-1-reimport".to_string();
    store.save_host(same_name).unwrap();
    assert_eq!(store.load_hosts().unwrap().len(), 1);

    let jh = JumpHost {
        id: "jump-1".to_string(),
        name: "Jump 1".to_string(),
        hostname: "jump.test".to_string(),
        port: 2222,
        username: "jumpuser".to_string(),
        auth: AuthMethod::Password("jumppwd".to_string()),
    };
    store.save_jump_host(jh).unwrap();
    let loaded_jh = store.load_jump_hosts().unwrap();
    assert_eq!(loaded_jh.len(), 1);
    assert_eq!(loaded_jh[0].hostname, "jump.test");

    // Delete the latest re-imported record (same name, refreshed ID).
    assert!(store.delete_host("host-1-reimport").unwrap());
    assert_eq!(store.load_hosts().unwrap().len(), 0);

    // Clean up
    let _ = std::fs::remove_dir_all(tmp_dir);
}
