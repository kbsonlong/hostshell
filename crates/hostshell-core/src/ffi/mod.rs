use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use tokio::runtime::Runtime;
use tokio::sync::mpsc::UnboundedSender;

use crate::model::host::{Host, JumpHost};
use crate::model::stage::StageEvent;
use crate::ssh::session::{SessionCommand, SshSession};
use crate::storage::config_store::ConfigStore;
use crate::storage::importer::parse_ssh_config;

pub struct EngineWrapper {
    pub runtime: Runtime,
    pub store: ConfigStore,
}

pub struct SessionWrapper {
    pub cmd_tx: UnboundedSender<SessionCommand>,
}

#[no_mangle]
pub extern "C" fn hostshell_engine_init() -> *mut EngineWrapper {
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
    }))
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
pub extern "C" fn hostshell_import_ssh_config(_engine: *mut EngineWrapper, config_text: *const c_char) -> *mut c_char {
    if config_text.is_null() {
        return std::ptr::null_mut();
    }
    let c_str = unsafe { CStr::from_ptr(config_text) };
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let res = parse_ssh_config(str_slice);
    let json = serde_json::json!({
        "hosts": res.hosts,
        "warnings": res.warnings,
    });
    CString::new(json.to_string()).unwrap_or_default().into_raw()
}

// --- Session Connection & PTY ---
type StageCallback = extern "C" fn(event_json: *const c_char, user_data: *mut c_void);
type OutputCallback = extern "C" fn(data: *const u8, len: usize, user_data: *mut c_void);

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
        Err(_) => return std::ptr::null_mut(),
    };

    let all_jump_hosts = eng.store.load_jump_hosts().unwrap_or_default();
    let selected_jump_hosts: Vec<JumpHost> = host
        .jump_host_ids
        .iter()
        .filter_map(|jid| all_jump_hosts.iter().find(|j| &j.id == jid).cloned())
        .collect();

    let known_hosts = eng.store.known_hosts_ref();
    let user_data_addr = user_data as usize;

    let result = eng.runtime.block_on(async {
        SshSession::connect(
            host,
            selected_jump_hosts,
            known_hosts,
            cols,
            rows,
            auto_accept_new_keys,
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
