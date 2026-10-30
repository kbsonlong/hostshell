use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::error::{HostShellError, Result};
use crate::model::host::{Host, JumpHost};
use crate::model::known_host::KnownHostsStore;

#[derive(Clone)]
pub struct ConfigStore {
    base_dir: PathBuf,
    known_hosts: Arc<Mutex<KnownHostsStore>>,
}

impl ConfigStore {
    pub fn new() -> Result<Self> {
        let base_dir = Self::default_data_dir()?;
        fs::create_dir_all(&base_dir).map_err(HostShellError::Io)?;

        let store = Self {
            base_dir,
            known_hosts: Arc::new(Mutex::new(KnownHostsStore::new())),
        };

        // Try load existing known hosts
        if let Ok(kh) = store.load_known_hosts() {
            if let Ok(mut guard) = store.known_hosts.lock() {
                *guard = kh;
            }
        }

        Ok(store)
    }

    pub fn with_dir(dir: PathBuf) -> Result<Self> {
        fs::create_dir_all(&dir).map_err(HostShellError::Io)?;
        let store = Self {
            base_dir: dir,
            known_hosts: Arc::new(Mutex::new(KnownHostsStore::new())),
        };
        if let Ok(kh) = store.load_known_hosts() {
            if let Ok(mut guard) = store.known_hosts.lock() {
                *guard = kh;
            }
        }
        Ok(store)
    }

    pub fn known_hosts_ref(&self) -> Arc<Mutex<KnownHostsStore>> {
        self.known_hosts.clone()
    }

    fn default_data_dir() -> Result<PathBuf> {
        if let Some(home) = std::env::var_os("HOME") {
            let mut p = PathBuf::from(home);
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            {
                p.push("Library");
                p.push("Application Support");
                p.push("HostShell");
            }
            #[cfg(not(any(target_os = "macos", target_os = "ios")))]
            {
                p.push(".config");
                p.push("hostshell");
            }
            Ok(p)
        } else {
            Ok(PathBuf::from("./.hostshell"))
        }
    }

    // --- Hosts CRUD ---
    pub fn load_hosts(&self) -> Result<Vec<Host>> {
        let file_path = self.base_dir.join("hosts.json");
        if !file_path.exists() {
            return Ok(Vec::new());
        }
        let data = fs::read_to_string(&file_path).map_err(HostShellError::Io)?;
        let hosts: Vec<Host> = serde_json::from_str(&data)?;
        Ok(hosts)
    }

    pub fn save_hosts(&self, hosts: &[Host]) -> Result<()> {
        let file_path = self.base_dir.join("hosts.json");
        let data = serde_json::to_string_pretty(hosts)?;
        fs::write(&file_path, data).map_err(HostShellError::Io)?;
        Ok(())
    }

    pub fn save_host(&self, host: Host) -> Result<()> {
        let mut hosts = self.load_hosts().unwrap_or_default();
        // Replace by id, and also by name (re-import / rename flows would
        // otherwise append duplicate entries).
        hosts.retain(|h| h.id != host.id && h.name != host.name);
        hosts.push(host);
        self.save_hosts(&hosts)
    }

    pub fn delete_host(&self, id: &str) -> Result<bool> {
        let mut hosts = self.load_hosts().unwrap_or_default();
        let prev = hosts.len();
        hosts.retain(|h| h.id != id);
        if hosts.len() < prev {
            self.save_hosts(&hosts)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    // --- JumpHosts CRUD ---
    pub fn load_jump_hosts(&self) -> Result<Vec<JumpHost>> {
        let file_path = self.base_dir.join("jumphosts.json");
        if !file_path.exists() {
            return Ok(Vec::new());
        }
        let data = fs::read_to_string(&file_path).map_err(HostShellError::Io)?;
        let jump_hosts: Vec<JumpHost> = serde_json::from_str(&data)?;
        Ok(jump_hosts)
    }

    pub fn save_jump_hosts(&self, jump_hosts: &[JumpHost]) -> Result<()> {
        let file_path = self.base_dir.join("jumphosts.json");
        let data = serde_json::to_string_pretty(jump_hosts)?;
        fs::write(&file_path, data).map_err(HostShellError::Io)?;
        Ok(())
    }

    pub fn save_jump_host(&self, jh: JumpHost) -> Result<()> {
        let mut list = self.load_jump_hosts().unwrap_or_default();
        list.retain(|j| j.id != jh.id && j.name != jh.name);
        list.push(jh);
        self.save_jump_hosts(&list)
    }

    pub fn delete_jump_host(&self, id: &str) -> Result<bool> {
        let mut list = self.load_jump_hosts().unwrap_or_default();
        let prev = list.len();
        list.retain(|j| j.id != id);
        if list.len() < prev {
            self.save_jump_hosts(&list)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    // --- Known Hosts Persistence ---
    pub fn load_known_hosts(&self) -> Result<KnownHostsStore> {
        let file_path = self.base_dir.join("known_hosts.json");
        if !file_path.exists() {
            return Ok(KnownHostsStore::new());
        }
        let data = fs::read_to_string(&file_path).map_err(HostShellError::Io)?;
        let store: KnownHostsStore = serde_json::from_str(&data)?;
        Ok(store)
    }

    pub fn persist_known_hosts(&self) -> Result<()> {
        let store = self
            .known_hosts
            .lock()
            .map_err(|e| HostShellError::Config(format!("Lock poisoned: {}", e)))?
            .clone();
        let file_path = self.base_dir.join("known_hosts.json");
        let data = serde_json::to_string_pretty(&store)?;
        fs::write(&file_path, data).map_err(HostShellError::Io)?;
        Ok(())
    }
}
