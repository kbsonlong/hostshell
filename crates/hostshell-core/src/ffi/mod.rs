use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use tokio::runtime::Runtime;
use tokio::sync::mpsc::UnboundedSender;

use crate::model::host::{Host, JumpHost};
use crate::model::stage::StageEvent;
use crate::ssh::session::{SessionCommand, SshSession};
use crate::storage::config_store::ConfigStore;
use crate::storage::importer::parse_ssh_config_with_existing;

pub struct EngineWrapper {
    pub runtime: Runtime,
    pub store: ConfigStore,
    #[cfg(target_os = "macos")]
    _log_guard: Option<tracing_appender::non_blocking::WorkerGuard>,
}

pub struct SessionWrapper {
    pub cmd_tx: UnboundedSender<SessionCommand>,
}

#[cfg(target_os = "macos")]
fn desktop_log_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .map(|home| home.join("Library/Logs/HostShell"))
}

#[cfg(target_os = "macos")]
fn init_desktop_logging() -> Option<tracing_appender::non_blocking::WorkerGuard> {
    use tracing_subscriber::prelude::*;

    let log_dir = desktop_log_dir()?;
    if std::fs::create_dir_all(&log_dir).is_err() {
        return None;
    }
    let appender = tracing_appender::rolling::never(log_dir, "hostshell.log");
    let (writer, guard) = tracing_appender::non_blocking(appender);
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let subscriber = tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer().with_ansi(false).with_writer(writer));
    let _ = tracing::subscriber::set_global_default(subscriber);
    tracing::info!("HostShell desktop diagnostic logging initialized; credentials and terminal output are excluded");
    Some(guard)
}

#[no_mangle]
pub extern "C" fn hostshell_engine_init() -> *mut EngineWrapper {
    #[cfg(target_os = "macos")]
    let log_guard = init_desktop_logging();

    let rt = match Runtime::new() {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };

    let store = match ConfigStore::new() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    Box::into_raw(Box::new(EngineWrapper {
        runtime: rt,
        store,
        #[cfg(target_os = "macos")]
        _log_guard: log_guard,
    }))
}

#[no_mangle]
pub extern "C" fn hostshell_log_directory() -> *mut c_char {
    #[cfg(target_os = "macos")]
    {
        if let Some(path) = desktop_log_dir() {
            if std::fs::create_dir_all(&path).is_ok() {
                if let Ok(c_path) = CString::new(path.to_string_lossy().as_bytes()) {
                    return c_path.into_raw();
                }
            }
        }
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn hostshell_engine_free(engine: *mut EngineWrapper) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

#[no_mangle]
pub extern "C" fn hostshell_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[no_mangle]
pub extern "C" fn hostshell_list_keys(engine: *mut EngineWrapper) -> *mut c_char {
    if engine.is_null() { return std::ptr::null_mut(); }
    let store = unsafe { &(*engine).store };
    match store.load_keys().and_then(|keys| Ok(serde_json::to_string(&keys)?)) {
        Ok(json) => CString::new(json).unwrap_or_default().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn hostshell_add_key(engine: *mut EngineWrapper, json: *const c_char) -> *mut c_char {
    let result = (|| -> std::result::Result<(), String> {
        if engine.is_null() || json.is_null() { return Err("无效请求".into()); }
        let store = unsafe { &(*engine).store };
        let value: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(json) }.to_str().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        let name = value["name"].as_str().unwrap_or("").trim();
        let key_data = value["key_data"].as_str().unwrap_or("");
        if name.is_empty() || key_data.is_empty() { return Err("请输入名称和私钥".into()); }
        let mut keys = store.load_keys().map_err(|e| e.to_string())?;
        let key = crate::storage::keys::make_key(name.to_string(), key_data.to_string(), value["passphrase"].as_str().filter(|p| !p.is_empty()).map(str::to_owned))?;
        keys.push(key.clone());
        if let Err(error) = store.save_keys(&keys) {
            let _ = crate::storage::keys::delete_key(&key.id);
            return Err(error.to_string());
        }
        Ok(())
    })();
    let response = match result { Ok(()) => serde_json::json!({"ok":true}), Err(e) => serde_json::json!({"ok":false,"error":e}) };
    CString::new(response.to_string()).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn hostshell_delete_key(engine: *mut EngineWrapper, id: *const c_char) -> c_int {
    if engine.is_null() || id.is_null() { return -1; }
    let store = unsafe { &(*engine).store };
    let Ok(id) = unsafe { CStr::from_ptr(id) }.to_str() else { return -1; };
    let Ok(hosts) = store.load_hosts() else { return -1; };
    let Ok(jumps) = store.load_jump_hosts() else { return -1; };
    let referenced = |auth: &crate::model::host::AuthMethod| matches!(auth, crate::model::host::AuthMethod::KeyRef { id: key_id } if key_id == id);
    if hosts.iter().any(|h| referenced(&h.auth) || h.forward_agent_key_ids.iter().any(|key_id| key_id == id)) || jumps.iter().any(|j| referenced(&j.auth)) { return -2; }
    let Ok(mut keys) = store.load_keys() else { return -1; };
    if !keys.iter().any(|key| key.id == id) { return -1; }
    if crate::storage::keys::delete_key(id).is_err() { return -1; }
    keys.retain(|key| key.id != id);
    if store.save_keys(&keys).is_err() { return -1; }
    0
}

// --- Hosts CRUD ---
#[no_mangle]
pub extern "C" fn hostshell_list_hosts(engine: *mut EngineWrapper) -> *mut c_char {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let eng = unsafe { &*engine };
    let hosts = eng.store.load_hosts().unwrap_or_default();
    let json = serde_json::to_string(&hosts).unwrap_or_else(|_| "[]".to_string());
    CString::new(json).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn hostshell_save_host(engine: *mut EngineWrapper, host_json: *const c_char) -> c_int {
    if engine.is_null() || host_json.is_null() {
        return -1;
    }
    let eng = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(host_json) };
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    let host: Host = match serde_json::from_str(str_slice) {
        Ok(h) => h,
        Err(_) => return -2,
    };

    match eng.store.save_host(host) {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn hostshell_delete_host(engine: *mut EngineWrapper, host_id: *const c_char) -> c_int {
    if engine.is_null() || host_id.is_null() {
        return -1;
    }
    let eng = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(host_id) };
    let id_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    match eng.store.delete_host(id_str) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(_) => -2,
    }
}

// --- JumpHosts CRUD ---
#[no_mangle]
pub extern "C" fn hostshell_list_jump_hosts(engine: *mut EngineWrapper) -> *mut c_char {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let eng = unsafe { &*engine };
    let jh = eng.store.load_jump_hosts().unwrap_or_default();
    let json = serde_json::to_string(&jh).unwrap_or_else(|_| "[]".to_string());
    CString::new(json).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn hostshell_save_jump_host(engine: *mut EngineWrapper, jh_json: *const c_char) -> c_int {
    if engine.is_null() || jh_json.is_null() {
        return -1;
    }
    let eng = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(jh_json) };
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    let jh: JumpHost = match serde_json::from_str(str_slice) {
        Ok(j) => j,
        Err(_) => return -2,
    };

    match eng.store.save_jump_host(jh) {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

#[no_mangle]
pub extern "C" fn hostshell_delete_jump_host(engine: *mut EngineWrapper, jh_id: *const c_char) -> c_int {
    if engine.is_null() || jh_id.is_null() {
        return -1;
    }
    let eng = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(jh_id) };
    let id_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    match eng.store.delete_jump_host(id_str) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(_) => -2,
    }
}

// --- Import SSH Config ---
#[no_mangle]
pub extern "C" fn hostshell_import_ssh_config(engine: *mut EngineWrapper, config_text: *const c_char) -> *mut c_char {
    if config_text.is_null() {
        return std::ptr::null_mut();
    }
    let c_str = unsafe { CStr::from_ptr(config_text) };
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let (hosts, jumps) = if engine.is_null() { (vec![], vec![]) } else {
        let store = unsafe { &(*engine).store };
        (store.load_hosts().unwrap_or_default(), store.load_jump_hosts().unwrap_or_default())
    };
    let res = parse_ssh_config_with_existing(str_slice, &hosts, &jumps);
    let json = serde_json::json!({
        "hosts": res.hosts,
        "jump_hosts": res.jump_hosts,
        "warnings": res.warnings,
    });
    CString::new(json.to_string()).unwrap_or_default().into_raw()
}

// --- Session Connection & PTY ---
type StageCallback = extern "C" fn(event_json: *const c_char, user_data: *mut c_void);
type OutputCallback = extern "C" fn(data: *const u8, len: usize, user_data: *mut c_void);
type AuthInputCallback = extern "C" fn(
    name: *const c_char,
    instructions: *const c_char,
    prompt: *const c_char,
    echo: bool,
    response: *mut c_char,
    response_capacity: usize,
    user_data: *mut c_void,
) -> c_int;

#[no_mangle]
pub extern "C" fn hostshell_connect(
    engine: *mut EngineWrapper,
    host_json: *const c_char,
    cols: u32,
    rows: u32,
    auto_accept_new_keys: bool,
    stage_cb: Option<StageCallback>,
    output_cb: Option<OutputCallback>,
    user_data: *mut c_void,
) -> *mut SessionWrapper {
    hostshell_connect_with_auth_input(
        engine,
        host_json,
        cols,
        rows,
        auto_accept_new_keys,
        stage_cb,
        output_cb,
        None,
        user_data,
    )
}

#[no_mangle]
pub extern "C" fn hostshell_connect_with_auth_input(
    engine: *mut EngineWrapper,
    host_json: *const c_char,
    cols: u32,
    rows: u32,
    auto_accept_new_keys: bool,
    stage_cb: Option<StageCallback>,
    output_cb: Option<OutputCallback>,
    auth_input_cb: Option<AuthInputCallback>,
    user_data: *mut c_void,
) -> *mut SessionWrapper {
    if engine.is_null() || host_json.is_null() {
        return std::ptr::null_mut();
    }
    let eng = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(host_json) };
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let host: Host = match serde_json::from_str(str_slice) {
        Ok(h) => h,
        Err(e) => {
            tracing::error!("Rejected malformed host configuration JSON: {e}");
            return std::ptr::null_mut();
        }
    };
    tracing::info!(
        "Starting SSH session: host={} endpoint={}:{} user={} proxy={:?} auth={}",
        host.name,
        host.hostname,
        host.port,
        host.username,
        host.proxy_mode,
        match host.auth { crate::model::host::AuthMethod::Agent => "agent", crate::model::host::AuthMethod::Password(_) => "password", crate::model::host::AuthMethod::PrivateKey { .. } | crate::model::host::AuthMethod::KeyRef { .. } => "private_key" }
    );

    let all_jump_hosts = eng.store.load_jump_hosts().unwrap_or_default();
    let selected_jump_hosts: Vec<JumpHost> = host
        .jump_host_ids
        .iter()
        .filter_map(|jid| all_jump_hosts.iter().find(|j| &j.id == jid).cloned())
        .collect();

    let known_hosts = eng.store.known_hosts_ref();
    let stored_hosts = eng.store.load_hosts().unwrap_or_default();
    let user_data_addr = user_data as usize;
    let auth_input = auth_input_cb.map(|callback| {
        move |name: &str, instructions: &str, prompt: &str, echo: bool| {
            const RESPONSE_CAPACITY: usize = 4096;
            let to_cstring = |value: &str| CString::new(value.replace('\0', ""))
                .unwrap_or_else(|_| CString::default());
            let name = to_cstring(name);
            let instructions = to_cstring(instructions);
            let prompt = to_cstring(prompt);
            let mut response = vec![0u8; RESPONSE_CAPACITY];
            let len = callback(
                name.as_ptr(),
                instructions.as_ptr(),
                prompt.as_ptr(),
                echo,
                response.as_mut_ptr().cast(),
                response.len(),
                user_data_addr as *mut c_void,
            );
            if len == -1 {
                return Err("用户取消了交互式认证".to_string());
            }
            if len < 0 || len as usize > response.len() {
                return Err("交互式认证响应无效或超出长度限制".to_string());
            }
            String::from_utf8(response[..len as usize].to_vec())
                .map_err(|_| "交互式认证响应不是有效 UTF-8".to_string())
        }
    });

    let result = eng.runtime.block_on(async {
        SshSession::connect_with_auth_input(
            host,
            selected_jump_hosts,
            stored_hosts,
            known_hosts,
            cols,
            rows,
            auto_accept_new_keys,
            auth_input
                .as_ref()
                .map(|provider| provider as &crate::ssh::session::AuthInputProvider),
        )
        .await
    });

    match result {
        Ok(mut handle) => {
            let cmd_tx = handle.cmd_tx.clone();

            eng.runtime.spawn(async move {
                loop {
                    tokio::select! {
                        stage_evt = handle.stage_rx.recv() => {
                            match stage_evt {
                                Some(evt) => {
                                    tracing::info!("SSH session stage: {:?}", evt.stage);
                                    if let Some(cb) = stage_cb {
                                        if let Ok(json_str) = serde_json::to_string(&evt) {
                                            if let Ok(c_json) = CString::new(json_str) {
                                                cb(c_json.as_ptr(), user_data_addr as *mut c_void);
                                            }
                                        }
                                    }
                                }
                                None => break,
                            }
                        }
                        out = handle.output_rx.recv() => {
                            match out {
                                Some(data) => {
                                    if let Some(cb) = output_cb {
                                        cb(data.as_ptr(), data.len(), user_data_addr as *mut c_void);
                                    }
                                }
                                None => break,
                            }
                        }
                    }
                }
            });

            Box::into_raw(Box::new(SessionWrapper { cmd_tx }))
        }
        Err(e) => {
            if let Some(cb) = stage_cb {
                let fail_evt = StageEvent::now(crate::model::stage::ConnectionStage::Failed {
                    failed_stage: "InitialConnect".to_string(),
                    error_category: "ConnectError".to_string(),
                    message: e.to_string(),
                    suggestion: "Check connection details and try again.".to_string(),
                });
                if let Ok(json_str) = serde_json::to_string(&fail_evt) {
                    if let Ok(c_json) = CString::new(json_str) {
                        cb(c_json.as_ptr(), user_data_addr as *mut c_void);
                    }
                }
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn hostshell_session_write(
    session: *mut SessionWrapper,
    data: *const u8,
    len: usize,
) -> c_int {
    if session.is_null() || data.is_null() || len == 0 {
        return -1;
    }
    let sess = unsafe { &*session };
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    match sess.cmd_tx.send(SessionCommand::Write(slice.to_vec())) {
        Ok(_) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn hostshell_session_resize(
    session: *mut SessionWrapper,
    cols: u32,
    rows: u32,
) -> c_int {
    if session.is_null() {
        return -1;
    }
    let sess = unsafe { &*session };
    match sess.cmd_tx.send(SessionCommand::Resize { cols, rows }) {
        Ok(_) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn hostshell_session_close(session: *mut SessionWrapper) {
    if !session.is_null() {
        unsafe {
            let sess = Box::from_raw(session);
            let _ = sess.cmd_tx.send(SessionCommand::Close);
        }
    }
}
