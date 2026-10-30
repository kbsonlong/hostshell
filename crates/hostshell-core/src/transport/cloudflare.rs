use std::time::Duration;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;

use crate::error::{HostShellError, Result};
use crate::model::host::{CloudflareAuthType, CloudflareConfig};
use crate::transport::stream::BoxedStream;
use crate::transport::ws_adapter::WsStreamAdapter;

pub async fn connect_cloudflare(
    target_hostname: &str,
    config: &CloudflareConfig,
    timeout_duration: Duration,
) -> Result<BoxedStream> {
    let hostname = config
        .hostname_override
        .as_deref()
        .unwrap_or(target_hostname);

    let url_str = format!("wss://{}/", hostname);
    tracing::debug!("Connecting to Cloudflare Access WebSocket at {}", url_str);

    let mut request = url_str
        .as_str()
        .into_client_request()
        .map_err(|e| HostShellError::Cloudflare(format!("Invalid URL '{}': {}", url_str, e)))?;

    match config.auth_type {
        CloudflareAuthType::ServiceToken => {
            let client_id = config.client_id.as_deref().unwrap_or_default();
            let client_secret = config.client_secret.as_deref().unwrap_or_default();

            if client_id.is_empty() || client_secret.is_empty() {
                return Err(HostShellError::Cloudflare(
                    "Service Token Client ID and Client Secret must not be empty".to_string(),
                ));
            }

            let id_header = HeaderValue::from_str(client_id)
                .map_err(|e| HostShellError::Cloudflare(format!("Invalid Client ID header: {}", e)))?;
            let secret_header = HeaderValue::from_str(client_secret)
                .map_err(|e| HostShellError::Cloudflare(format!("Invalid Client Secret header: {}", e)))?;

            request.headers_mut().insert("CF-Access-Client-Id", id_header);
            request.headers_mut().insert("CF-Access-Client-Secret", secret_header);
        }
        CloudflareAuthType::WebSso => {
            let cookie_token = config.cookie.as_deref().unwrap_or_default();
            if cookie_token.is_empty() {
                return Err(HostShellError::Cloudflare(
                    "CF_Authorization SSO cookie/token is required".to_string(),
                ));
            }

            let cookie_val = format!("CF_Authorization={}", cookie_token);
            let cookie_header = HeaderValue::from_str(&cookie_val)
                .map_err(|e| HostShellError::Cloudflare(format!("Invalid Cookie header: {}", e)))?;

            request.headers_mut().insert("Cookie", cookie_header);
        }
    }

    let (ws_stream, response) = timeout(timeout_duration, connect_async(request))
        .await
        .map_err(|_| HostShellError::Cloudflare("Cloudflare Access WSS handshake timed out".to_string()))?
        .map_err(|e| HostShellError::Cloudflare(format!("Cloudflare Access WSS connection failed: {}", e)))?;

    tracing::info!(
        "Cloudflare Access WSS connected successfully with HTTP status {}",
        response.status()
    );

    let adapter = WsStreamAdapter::new(ws_stream);
    Ok(Box::pin(adapter) as BoxedStream)
}
