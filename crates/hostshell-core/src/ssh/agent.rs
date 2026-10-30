use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use futures_util::stream;
use russh::keys::agent::{client::AgentClient, server::{self, MessageType}};
use tokio::io::DuplexStream;
use tokio::sync::mpsc;

#[derive(Clone)]
struct Policy(Arc<AtomicBool>);

impl server::Agent for Policy {
    async fn confirm_request(&self, message: MessageType) -> bool {
        match message {
            MessageType::RequestKeys | MessageType::Sign => true,
            MessageType::AddKeys => self.0.load(Ordering::Acquire),
            _ => false,
        }
    }
}

#[derive(Clone)]
pub struct AppAgent {
    streams: mpsc::UnboundedSender<DuplexStream>,
}

impl AppAgent {
    pub async fn new(keys: &[russh::keys::PrivateKey]) -> Result<Self, String> {
        let (streams, rx) = mpsc::unbounded_channel();
        let policy = Policy(Arc::new(AtomicBool::new(true)));
        let listener = stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|stream| (Ok(stream), rx))
        });
        // Box the listener because serve requires an Unpin stream.
        let listener = Box::pin(listener);
        let server_policy = policy.clone();
        tokio::spawn(async move {
            if let Err(error) = server::serve(listener, server_policy).await {
                tracing::warn!("Application SSH agent stopped: {error}");
            }
        });
        let agent = Self { streams };
        let mut client = AgentClient::connect(agent.open()?);
        for key in keys {
            client.add_identity(key, &[]).await.map_err(|e| format!("无法加载转发密钥: {e}"))?;
        }
        policy.0.store(false, Ordering::Release);
        Ok(agent)
    }

    pub fn open(&self) -> Result<DuplexStream, String> {
        let (client, server) = tokio::io::duplex(64 * 1024);
        self.streams.send(server).map_err(|_| "应用内 SSH Agent 已关闭".to_string())?;
        Ok(client)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn serves_selected_identity_and_rejects_remote_mutation() {
        let key = russh::keys::PrivateKey::random(
            &mut rand::rng(), russh::keys::ssh_key::Algorithm::Ed25519,
        ).unwrap();
        let agent = AppAgent::new(&[key]).await.unwrap();
        let mut client = AgentClient::connect(agent.open().unwrap());
        let identities = client.request_identities().await.unwrap();
        assert_eq!(identities.len(), 1);
        assert!(!client.sign_request(&identities[0], None, b"test".to_vec()).await.unwrap().is_empty());
        assert!(client.remove_all_identities().await.is_err());
        let mut client = AgentClient::connect(agent.open().unwrap());
        assert_eq!(client.request_identities().await.unwrap().len(), 1);
    }
}
