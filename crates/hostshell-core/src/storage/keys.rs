use serde::{Deserialize, Serialize};
use crate::model::host::AuthMethod;

const SERVICE: &str = "com.hostshell.ssh-private-key";

#[derive(Clone, Serialize, Deserialize)]
pub struct KeyMetadata {
    pub id: String,
    pub name: String,
    pub fingerprint: String,
    pub algorithm: String,
}

#[derive(Serialize, Deserialize)]
struct KeySecret { key_data: String, passphrase: Option<String> }

pub fn make_key(name: String, key_data: String, passphrase: Option<String>) -> Result<KeyMetadata, String> {
    let key_data = key_data.replace('\r', "");
    let key = russh::keys::decode_secret_key(&key_data, passphrase.as_deref()).map_err(|e| format!("私钥或密码无效: {e}"))?;
    let metadata = KeyMetadata {
        id: uuid::Uuid::new_v4().to_string(), name,
        fingerprint: key.public_key().fingerprint(russh::keys::HashAlg::Sha256).to_string(),
        algorithm: key.algorithm().to_string(),
    };
    let data = serde_json::to_vec(&KeySecret { key_data, passphrase }).map_err(|e| e.to_string())?;
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    security_framework::passwords::set_generic_password(SERVICE, &metadata.id, &data).map_err(|e| format!("Keychain 保存失败: {e}"))?;
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    { let _ = data; return Err("当前平台不支持 Keychain".into()); }
    #[allow(unreachable_code)]
    Ok(metadata)
}

pub fn resolve_auth(auth: &AuthMethod) -> Result<AuthMethod, String> {
    let AuthMethod::KeyRef { id } = auth else { return Ok(auth.clone()); };
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let data = security_framework::passwords::get_generic_password(SERVICE, id).map_err(|e| format!("无法读取 Keychain 私钥: {e}"))?;
        let secret: KeySecret = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
        Ok(AuthMethod::PrivateKey { key_data: secret.key_data, passphrase: secret.passphrase })
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    { let _ = id; Err("当前平台不支持 Keychain".into()) }
}

pub fn delete_key(id: &str) -> Result<(), String> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    { security_framework::passwords::delete_generic_password(SERVICE, id).map_err(|e| e.to_string()) }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    { let _ = id; Err("当前平台不支持 Keychain".into()) }
}
