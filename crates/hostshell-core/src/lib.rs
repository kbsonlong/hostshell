pub mod error;
pub mod ffi;
pub mod model;
pub mod ssh;
pub mod storage;
pub mod transport;

pub use error::{HostShellError, Result};
pub use model::*;
pub use ssh::{SessionCommand, SessionHandle, SshSession};
pub use storage::{parse_ssh_config, ConfigStore, ImportResult};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
