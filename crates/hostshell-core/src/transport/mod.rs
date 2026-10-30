pub mod bastion;
pub mod cloudflare;
pub mod direct;
pub mod proxy_command;
pub mod stream;
pub mod ws_adapter;

pub use bastion::connect_bastion_chain;
pub use cloudflare::connect_cloudflare;
pub use direct::connect_direct;
pub use proxy_command::connect_proxy_command;
pub use stream::{AsyncStream, BoxedStream};
