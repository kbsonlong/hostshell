use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use hostshell_core::model::host::{AuthMethod, Host, JumpHost, ProxyMode};
use hostshell_core::model::stage::ConnectionStage;
use hostshell_core::ssh::session::SshSession;
use hostshell_core::storage::config_store::ConfigStore;
use hostshell_core::storage::importer::parse_ssh_config;

// ── raw terminal helpers ──────────────────────────────────────────────────────

#[cfg(unix)]
mod terminal {
    use std::os::unix::io::AsRawFd;

    /// Save the current termios state and switch stdin to raw mode.
    /// Returns the saved state so the caller can restore it.
    pub fn enable_raw_mode() -> Option<libc::termios> {
        let fd = std::io::stdin().as_raw_fd();
        unsafe {
            let mut old: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(fd, &mut old) != 0 {
                return None;
            }
            let mut raw = old;
            libc::cfmakeraw(&mut raw);
            // Keep software flow control disabled, allow Ctrl-C to reach us
            raw.c_cc[libc::VMIN] = 1;
            raw.c_cc[libc::VTIME] = 0;
            libc::tcsetattr(fd, libc::TCSANOW, &raw);
            Some(old)
        }
    }

    pub fn restore_terminal(saved: libc::termios) {
        let fd = std::io::stdin().as_raw_fd();
        unsafe {
            libc::tcsetattr(fd, libc::TCSANOW, &saved);
        }
    }

    pub fn terminal_size() -> (u32, u32) {
        let fd = std::io::stdout().as_raw_fd();
        unsafe {
            let mut ws: libc::winsize = std::mem::zeroed();
            if libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) == 0
                && ws.ws_col > 0
                && ws.ws_row > 0
            {
                return (ws.ws_col as u32, ws.ws_row as u32);
            }
        }
        (220, 50)
    }
}

#[cfg(not(unix))]
mod terminal {
    pub fn enable_raw_mode() -> Option<()> { None }
    pub fn restore_terminal(_: ()) {}
    pub fn terminal_size() -> (u32, u32) { (220, 50) }
}

fn expand_tilde(path: &str) -> String {
    if path.starts_with('~') {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{}{}", home, &path[1..]);
        }
    }
    path.to_string()
}

// ── entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Use a compact log format so it doesn't pollute the terminal session
    tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".to_string()),
        )
        .with_writer(std::io::stderr)
        .init();

    let args: Vec<String> = std::env::args().collect();
    let store = ConfigStore::new()?;

    if args.len() < 2 {
        print_usage();
        return Ok(());
    }

    match args[1].as_str() {
        "list" => cmd_list(&store)?,
        "list-jumps" => cmd_list_jumps(&store)?,
        "import" => cmd_import(&args, &store)?,
        "add" => cmd_add(&args, &store)?,
        "remove" => cmd_remove(&args, &store)?,
        "connect" => cmd_connect(&args, store).await?,
        "quick-connect" => cmd_quick_connect(&args, store).await?,
        cmd => {
            eprintln!("Unknown command: {}", cmd);
            print_usage();
        }
    }

    Ok(())
}

fn print_usage() {
    println!("HostShell CLI v{}", hostshell_core::version());
    println!();
    println!("Usage:");
    println!("  hostshell-cli list                         List configured hosts");
    println!("  hostshell-cli list-jumps                   List jump hosts");
    println!("  hostshell-cli import <ssh_config_file>     Import from ~/.ssh/config");
    println!("  hostshell-cli add <name> [options]         Add a host");
    println!("    --host <hostname>                        Target hostname (required)");
    println!("    --user <user>                            SSH username (default: $USER)");
    println!("    --port <port>                            SSH port (default: 22)");
    println!("    --password <pwd>                         Password auth");
    println!("    --identity-file <path>                   Private key file path");
    println!("    --proxy-command <cmd>                    ProxyCommand (supports %h / %p)");
    println!("  hostshell-cli remove <name_or_id>          Remove a host");
    println!("  hostshell-cli connect <name_or_id>         Connect (interactive session)");
    println!("  hostshell-cli quick-connect <u> <h> <p> <pwd>  One-shot password connect");
    println!();
    println!("Environment:");
    println!("  RUST_LOG=info    Enable verbose logging to stderr");
}

// ── subcommands ───────────────────────────────────────────────────────────────

fn cmd_list(store: &ConfigStore) -> Result<(), Box<dyn std::error::Error>> {
    let hosts = store.load_hosts()?;
    println!("=== Configured Hosts ({}) ===", hosts.len());
    for h in &hosts {
        let proxy_info = match &h.proxy_mode {
            ProxyMode::Direct => "direct".to_string(),
            ProxyMode::ProxyJump => format!("jump({})", h.jump_host_ids.join(",")),
            ProxyMode::CloudflareAccess => "cloudflare-wss".to_string(),
            ProxyMode::ProxyCommand => {
                let cmd = h.proxy_command.as_deref().unwrap_or("(unset)");
                let short: String = cmd.chars().take(40).collect();
                format!("proxy-cmd: {}", short)
            }
        };
        let auth_info = match &h.auth {
            AuthMethod::Password(_) => "password",
            AuthMethod::PrivateKey { .. } => "privatekey",
            AuthMethod::Agent => "agent",
        };
        println!(
            "  [{}] {} → {}@{}:{} | {} | auth:{}",
            h.id, h.name, h.username, h.hostname, h.port, proxy_info, auth_info
        );
    }
    Ok(())
}

fn cmd_list_jumps(store: &ConfigStore) -> Result<(), Box<dyn std::error::Error>> {
    let jumps = store.load_jump_hosts()?;
    println!("=== Jump Hosts ({}) ===", jumps.len());
    for j in &jumps {
        println!("  [{}] {} → {}@{}:{}", j.id, j.name, j.username, j.hostname, j.port);
    }
    Ok(())
}

fn cmd_import(args: &[String], store: &ConfigStore) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 3 {
        eprintln!("Usage: hostshell-cli import <path>");
        return Ok(());
    }
    let content = std::fs::read_to_string(&args[2])?;
    let res = parse_ssh_config(&content);
    println!("Imported {} host(s), {} warning(s):", res.hosts.len(), res.warnings.len());
    for h in &res.hosts {
        println!("  + {} (mode: {:?})", h.name, h.proxy_mode);
        store.save_host(h.clone())?;
    }
    for w in &res.warnings {
        println!("  ! {}", w);
    }
    Ok(())
}

fn cmd_add(args: &[String], store: &ConfigStore) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 3 {
        eprintln!("Usage: hostshell-cli add <name> --host <hostname> [options]");
        return Ok(());
    }
    let name = args[2].clone();

    let mut hostname = String::new();
    let mut username = std::env::var("USER").unwrap_or_else(|_| "root".to_string());
    let mut port: u16 = 22;
    let mut identity_file: Option<String> = None;
    let mut password: Option<String> = None;
    let mut proxy_command: Option<String> = None;

    let mut i = 3;
    while i < args.len() {
        match args[i].as_str() {
            "--host"          => { i += 1; if i < args.len() { hostname = args[i].clone(); } }
            "--user"          => { i += 1; if i < args.len() { username = args[i].clone(); } }
            "--port"          => { i += 1; if i < args.len() { port = args[i].parse().unwrap_or(22); } }
            "--identity-file" => { i += 1; if i < args.len() { identity_file = Some(args[i].clone()); } }
            "--password"      => { i += 1; if i < args.len() { password = Some(args[i].clone()); } }
            "--proxy-command" => {
                // Collect rest of the args as the command string
                i += 1;
                let cmd: Vec<&str> = args[i..].iter().map(String::as_str).collect();
                proxy_command = Some(cmd.join(" "));
                break;
            }
            _ => {}
        }
        i += 1;
    }

    if hostname.is_empty() {
        eprintln!("Error: --host is required");
        return Ok(());
    }

    let auth = if let Some(path) = &identity_file {
        let expanded = expand_tilde(path);
        let key_data = std::fs::read_to_string(&expanded)
            .map_err(|e| format!("Cannot read identity file '{}': {}", expanded, e))?;
        AuthMethod::PrivateKey { key_data, passphrase: None }
    } else if let Some(pwd) = password {
        AuthMethod::Password(pwd)
    } else {
        AuthMethod::Password(String::new())
    };

    let (proxy_mode, stored_cmd) = if let Some(ref cmd) = proxy_command {
        (ProxyMode::ProxyCommand, Some(cmd.clone()))
    } else {
        (ProxyMode::Direct, None)
    };

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let host = Host {
        id: uuid::Uuid::new_v4().to_string(),
        name: name.clone(),
        hostname: hostname.clone(),
        port,
        username: username.clone(),
        auth,
        proxy_mode,
        jump_host_ids: vec![],
        cloudflare_config: None,
        proxy_command: stored_cmd,
        tags: vec![],
        last_connected_at: None,
        created_at: now,
        updated_at: now,
    };

    store.save_host(host)?;
    println!("Added host '{}' ({}@{}:{})", name, username, hostname, port);
    Ok(())
}

fn cmd_remove(args: &[String], store: &ConfigStore) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 3 {
        eprintln!("Usage: hostshell-cli remove <name_or_id>");
        return Ok(());
    }
    let target = &args[2];
    let hosts = store.load_hosts()?;
    let host = hosts
        .into_iter()
        .find(|h| &h.name == target || &h.id == target)
        .ok_or_else(|| format!("Host '{}' not found", target))?;
    store.delete_host(&host.id)?;
    println!("Removed host '{}'", host.name);
    Ok(())
}

async fn cmd_connect(
    args: &[String],
    store: ConfigStore,
) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 3 {
        eprintln!("Usage: hostshell-cli connect <name_or_id>");
        return Ok(());
    }
    let target = &args[2];
    let hosts = store.load_hosts()?;
    let host = hosts
        .into_iter()
        .find(|h| &h.name == target || &h.id == target)
        .ok_or_else(|| format!("Host '{}' not found. Run 'list' to see available hosts.", target))?;

    let all_jumps = store.load_jump_hosts()?;
    let selected_jumps: Vec<JumpHost> = host
        .jump_host_ids
        .iter()
        .filter_map(|jid| all_jumps.iter().find(|j| &j.id == jid).cloned())
        .collect();

    run_interactive_session(host, selected_jumps, store).await
}

async fn cmd_quick_connect(
    args: &[String],
    store: ConfigStore,
) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 6 {
        eprintln!("Usage: hostshell-cli quick-connect <user> <host> <port> <password>");
        return Ok(());
    }
    let user = &args[2];
    let host_str = &args[3];
    let port: u16 = args[4].parse().unwrap_or(22);
    let password = &args[5];

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let h = Host {
        id: uuid::Uuid::new_v4().to_string(),
        name: format!("{}-quick", host_str),
        hostname: host_str.to_string(),
        port,
        username: user.to_string(),
        auth: AuthMethod::Password(password.to_string()),
        proxy_mode: ProxyMode::Direct,
        jump_host_ids: vec![],
        cloudflare_config: None,
        proxy_command: None,
        tags: vec![],
        last_connected_at: None,
        created_at: now,
        updated_at: now,
    };

    run_interactive_session(h, vec![], store).await
}

// ── interactive session ───────────────────────────────────────────────────────

async fn run_interactive_session(
    host: Host,
    jump_hosts: Vec<JumpHost>,
    store: ConfigStore,
) -> Result<(), Box<dyn std::error::Error>> {
    let host_name = host.name.clone();
    eprintln!("Connecting to {} ({:?})…", host_name, host.proxy_mode);

    let (cols, rows) = terminal::terminal_size();

    let known_hosts = store.known_hosts_ref();
    let session = SshSession::connect(host, jump_hosts, known_hosts, cols, rows, true).await?;

    let mut stage_rx = session.stage_rx;
    let mut output_rx = session.output_rx;
    let cmd_tx = session.cmd_tx;

    // Flag set when session terminates so the stdin thread can stop
    let done = Arc::new(AtomicBool::new(false));
    let done_clone = done.clone();

    // ── Stage event printer (runs on async task) ──────────────────────────
    tokio::spawn(async move {
        while let Some(evt) = stage_rx.recv().await {
            match evt.stage {
                ConnectionStage::ConnectingTransport { target, description } => {
                    eprintln!("[transport] {} — {}", target, description);
                }
                ConnectionStage::BastionConnecting { hop, total_hops, bastion_name } => {
                    eprintln!("[bastion {}/{}] connecting to {}", hop, total_hops, bastion_name);
                }
                ConnectionStage::BastionAuthenticated { hop, total_hops, bastion_name } => {
                    eprintln!("[bastion {}/{}] authenticated to {}", hop, total_hops, bastion_name);
                }
                ConnectionStage::BastionTunnelReady { hop, total_hops, target } => {
                    eprintln!("[bastion {}/{}] tunnel ready → {}", hop, total_hops, target);
                }
                ConnectionStage::CloudflareHandshaking { endpoint, auth_type } => {
                    eprintln!("[cloudflare] WSS → {} ({})", endpoint, auth_type);
                }
                ConnectionStage::CloudflareAuthenticated => {
                    eprintln!("[cloudflare] authenticated ✓");
                }
                ConnectionStage::SshHandshaking { target } => {
                    eprintln!("[ssh] handshaking with {}", target);
                }
                ConnectionStage::HostKeyPrompt { host, fingerprint, key_type } => {
                    eprintln!("[hostkey] {} ({}) — {}", host, key_type, fingerprint);
                }
                ConnectionStage::AuthenticatingUser { username, method } => {
                    eprintln!("[auth] {} via {}", username, method);
                }
                ConnectionStage::Connected { target } => {
                    eprintln!("[connected] {} ✓  (Ctrl-C or `exit` to quit)\r", target);
                }
                ConnectionStage::Disconnected { reason } => {
                    eprintln!("\r\n[disconnected] {}", reason);
                    break;
                }
                ConnectionStage::Failed { failed_stage, error_category, message, suggestion } => {
                    eprintln!(
                        "\r\n[ERROR] stage={} category={}\n  {}\n  hint: {}\n",
                        failed_stage, error_category, message, suggestion
                    );
                    break;
                }
                _ => {}
            }
        }
        done_clone.store(true, Ordering::Relaxed);
    });

    // ── SSH output → stdout ───────────────────────────────────────────────
    let done2 = done.clone();
    tokio::spawn(async move {
        let mut stdout = io::stdout();
        while let Some(chunk) = output_rx.recv().await {
            if stdout.write_all(&chunk).is_err() || stdout.flush().is_err() {
                break;
            }
        }
        done2.store(true, Ordering::Relaxed);
    });

    // ── stdin → SSH (OS thread to avoid blocking async runtime) ──────────
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let done3 = done.clone();
    std::thread::spawn(move || {
        let mut stdin = io::stdin();
        let mut buf = [0u8; 4096];
        while !done3.load(Ordering::Relaxed) {
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if stdin_tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    // ── Enable raw terminal mode ──────────────────────────────────────────
    let saved_term = terminal::enable_raw_mode();

    // ── Main loop: forward stdin to SSH ──────────────────────────────────
    loop {
        if done.load(Ordering::Relaxed) {
            break;
        }
        match stdin_rx.recv().await {
            Some(data) => {
                if cmd_tx
                    .send(hostshell_core::ssh::SessionCommand::Write(data))
                    .is_err()
                {
                    break;
                }
            }
            None => {
                // stdin closed (pipe/script mode): keep the session alive and
                // wait for the remote side to close, so output is not lost.
                while !done.load(Ordering::Relaxed) {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                break;
            }
        }
    }

    // ── Restore terminal ──────────────────────────────────────────────────
    if let Some(saved) = saved_term {
        terminal::restore_terminal(saved);
    }

    // Move cursor to fresh line after raw mode
    eprintln!("\r\nSession ended.");

    Ok(())
}
