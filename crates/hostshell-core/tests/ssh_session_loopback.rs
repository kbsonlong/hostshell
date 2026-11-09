use std::sync::{Arc, Mutex};
use std::time::Duration;

use hostshell_core::model::host::AuthMethod;
use hostshell_core::model::known_host::KnownHostsStore;
use hostshell_core::ssh::session::SshSession;
use hostshell_core::storage::importer::parse_ssh_config;
use russh::{Channel, ChannelId, Pty, server};
use tokio::sync::mpsc;

struct EchoServer {
    events: mpsc::UnboundedSender<(u32, u32)>,
}

impl server::Handler for EchoServer {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<server::Auth, Self::Error> {
        Ok(if user == "tester" && password == "test-password" { server::Auth::Accept } else { server::Auth::reject() })
    }

    async fn channel_open_session(&mut self, _channel: Channel<server::Msg>, reply: server::ChannelOpenHandle, _session: &mut server::Session) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(&mut self, channel: ChannelId, _term: &str, cols: u32, rows: u32, _width: u32, _height: u32, _modes: &[(Pty, u32)], session: &mut server::Session) -> Result<(), Self::Error> {
        let _ = self.events.send((cols, rows));
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(&mut self, channel: ChannelId, session: &mut server::Session) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }

    async fn window_change_request(&mut self, _channel: ChannelId, cols: u32, rows: u32, _width: u32, _height: u32, _session: &mut server::Session) -> Result<(), Self::Error> {
        let _ = self.events.send((cols, rows));
        Ok(())
    }

    async fn data(&mut self, channel: ChannelId, data: &[u8], session: &mut server::Session) -> Result<(), Self::Error> {
        session.data(channel, data.to_vec())?;
        Ok(())
    }
}

#[tokio::test]
async fn ssh_session_handles_pty_input_output_resize_and_close() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (events_tx, mut events_rx) = mpsc::unbounded_channel();
    let mut config = server::Config::default();
    config.keys.push(russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::ssh_key::Algorithm::Ed25519).unwrap());
    config.auth_rejection_time = Duration::ZERO;
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let session = server::run_stream(Arc::new(config), stream, EchoServer { events: events_tx }).await.unwrap();
        let _ = session.await;
    });
    let mut host = parse_ssh_config(&format!("Host test\n HostName 127.0.0.1\n Port {port}\n User tester\n")).hosts.remove(0);
    host.auth = AuthMethod::Password("test-password".into());
    let known = Arc::new(Mutex::new(KnownHostsStore::new()));
    let mut session = SshSession::connect(host, vec![], vec![], Arc::clone(&known), 80, 24, true).await.unwrap();
    assert_eq!(tokio::time::timeout(Duration::from_secs(3), events_rx.recv()).await.unwrap(), Some((80, 24)));
    session.send_input(b"hello\n").unwrap();
    let received = tokio::time::timeout(Duration::from_secs(3), async {
        let mut bytes = Vec::new();
        while bytes.len() < b"hello\n".len() {
            bytes.extend(session.output_rx.recv().await.expect("session closed before echo"));
        }
        bytes
    }).await.unwrap();
    assert_eq!(received, b"hello\n");
    session.resize(120, 40).unwrap();
    assert_eq!(tokio::time::timeout(Duration::from_secs(3), events_rx.recv()).await.unwrap(), Some((120, 40)));
    assert_eq!(known.lock().unwrap().entries.len(), 1);
    session.close().unwrap();
    tokio::time::timeout(Duration::from_secs(3), server).await.unwrap().unwrap();
}
