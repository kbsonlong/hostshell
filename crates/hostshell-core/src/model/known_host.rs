use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KnownHostEntry {
    pub hostname: String,
    pub port: u16,
    pub key_type: String,
    pub fingerprint: String,
    pub raw_public_key: String,
    pub added_at: u64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct KnownHostsStore {
    pub entries: Vec<KnownHostEntry>,
}

impl KnownHostsStore {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn find(&self, hostname: &str, port: u16) -> Option<&KnownHostEntry> {
        self.entries
            .iter()
            .find(|e| e.hostname == hostname && e.port == port)
    }

    pub fn add(&mut self, entry: KnownHostEntry) {
        self.entries
            .retain(|e| !(e.hostname == entry.hostname && e.port == entry.port));
        self.entries.push(entry);
    }

    pub fn remove(&mut self, hostname: &str, port: u16) -> bool {
        let prev = self.entries.len();
        self.entries
            .retain(|e| !(e.hostname == hostname && e.port == port));
        self.entries.len() < prev
    }
}
