# Cloudflare Access Service Token 配置指南

> 适用：HostShell 全端（macOS App / iOS App / CLI）
> 对应实现：`crates/hostshell-core/src/transport/cloudflare.rs`（`CloudflareAuthType::ServiceToken`）

## 1. 结论

**可以。** Service Token 是 Cloudflare 官方为自动化/无头场景设计的鉴权方式，全程在 Cloudflare Zero Trust 控制台配置，不需要浏览器参与、不需要 IdP 登录、没有会话过期（仅轮换/吊销）。HostShell 原生支持——WSS 握手时直接携带 `CF-Access-Client-Id` / `CF-Access-Client-Secret` 两个 HTTP header，与 cloudflared 行为等价。

两种 `auth_type` 对比：

| | ServiceToken | WebSso |
|---|---|---|
| 凭证 | Client ID + Client Secret | `CF_Authorization` cookie（JWT） |
| 获取方式 | 控制台创建，一次配置 | 浏览器 IdP 登录，需定期重新认证 |
| 有效期 | 永久（直到轮换/吊销） | 管理员设定的 session duration（如 24h） |
| 浏览器 | 不需要 | 需要 |
| 适用 | 人机/服务/长期使用 | 个人临时使用 |

## 2. 前置条件

- Cloudflare 账号已开启 **Zero Trust**（一个 organization）
- 目标 SSH 服务已通过 Access Application 暴露（通常是 self-hosted 应用 + `cloudflared` tunnel，应用域名形如 `ssh.example.com`）
- HostShell 端该主机的 `proxy_mode` 已设为 `cloudflare_access`

## 3. Cloudflare 控制台配置（两步）

### 3.1 创建 Service Token

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/) → **Zero Trust**
2. 进入 **Access controls → Service Auth → Service tokens**（旧版路径：Access → Service Auth）
3. **Create service token**，填写名称（如 `hostshell-macbook`）与 TTL（可选，建议设置以便强制轮换）
4. 创建成功后**立即保存**页面展示的两个值（Secret 只显示这一次）：
   - **Client ID**：形如 `hostshell-macbook.access`
   - **Client Secret**：2026-08-26 之后新建的为 `cfast_` 前缀格式（`cfast_` + 40 位字符 + 8 位校验位）

> ⚠️ Client Secret 等同于密码，不要提交进任何仓库。

### 3.2 在 Access 应用策略中放行该 Token

1. 进入 **Access controls → Applications**，打开目标 SSH 应用（或新建 Self-hosted 应用，域名填 `ssh.example.com`）
2. 在应用的 **Policies** 中 **Add a policy**：
   - **Action** 选 **Service Auth**（⚠️ 不是 `Allow`——选 `Allow` 时 Access 会跳 IdP 登录页，Service Token 反而会失败）
   - **Include → Selector** 选 **Service Auth**，选中 3.1 创建的 token（如 `hostshell-macbook`）
3. 保存

### 3.3 （推荐）开启 Strict Service Token Authentication

- 路径：**Access controls → Access settings → Manage service tokens → Strict service token authentication**
- 2026-10-05 之后新建的 Zero Trust organization 默认开启且**不可关闭**
- 开启后：token 只能用于 Include 了它的应用策略，未列出的应用一律 403，降低 token 泄露影响面

## 4. HostShell 端配置

### 4.1 GUI（macOS / iOS App）

编辑主机（HostEditSheet）：

| 字段 | 值 |
|---|---|
| Proxy Mode | `Cloudflare Access` |
| Auth Type | `Service Token` |
| Client ID | `hostshell-macbook.access` |
| Client Secret | `cfast_xxx...` |
| Hostname Override | 可选。当 SSH 目标主机名 ≠ Access 应用域名时填应用域名 |

保存后正常 `connect` 即可。

### 4.2 配置文件（hosts.json）

路径：`~/Library/Application Support/HostShell/hosts.json`（Linux 为 `~/.config/hostshell/`），对应 `CloudflareConfig`：

```json
{
  "id": "c6e91588-7809-462a-a42d-9bc228abbe13",
  "name": "office",
  "hostname": "ssh.example.com",
  "port": 22,
  "username": "zengshenglong",
  "auth": { "privateKey": { "path": "~/.ssh/id_ed25519" } },
  "proxy_mode": "cloudflare_access",
  "cloudflare_config": {
    "auth_type": "service_token",
    "client_id": "hostshell-macbook.access",
    "client_secret": "cfast_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "cookie": null,
    "hostname_override": null
  }
}
```

> 注：CLI 的 `add` 子命令暂不支持 Cloudflare 参数（`--cf-client-id` 等待实现），当前通过 GUI 或直接编辑 hosts.json 配置。

## 5. 工作原理

`connect_cloudflare()`（`transport/cloudflare.rs`）执行流程：

```
1. 构造 WSS 请求:  wss://<hostname>/   （hostname_override 优先）
2. 校验 client_id / client_secret 非空，否则拒绝发起
3. 注入 header:
     CF-Access-Client-Id: <client_id>
     CF-Access-Client-Secret: <client_secret>
4. tokio-tungstenite 发起 WSS 握手（带超时）
5. 握手通过 → WsStreamAdapter 把 WebSocket 封装成 AsyncRead+AsyncWrite
6. russh 在该流上执行 SSH handshake → 用户认证 → 交互会话
```

即 `SSH over WSS over TLS`，Access 边缘侧用 header 里的 Service Token 完成鉴权，无需任何浏览器或 IdP 交互。

## 6. 验证与排错

**快速验证（不依赖 HostShell）：**

```bash
curl -i \
  -H "CF-Access-Client-Id: hostshell-macbook.access" \
  -H "CF-Access-Client-Secret: cfast_xxx" \
  https://ssh.example.com/
```

- 返回 `200`/`302`（而非 302 到 IdP 登录页）→ token 与策略配置正确
- HostShell 内验证：`RUST_LOG=info ./target/release/hostshell-cli connect <name>`，观察 `CloudflareHandshaking → CloudflareAuthenticated` 阶段事件

**常见失败对照：**

| 现象 | 原因 | 处理 |
|---|---|---|
| 403 + 策略未命中 | 策略 Action 是 `Allow` 而非 `Service Auth` | 改为 Service Auth 并 Include 该 token |
| 403 严格模式 | 开了 Strict auth 但应用策略未 Include 此 token | 在该应用策略中 Include |
| 401/403 凭证错 | Secret 复制不全 / 含尾随空白 / 轮换后用旧值 | 重新复制，检查空格，确认 token 未被 Revoke |
| 握手超时 | 域名未接 Access / tunnel 未在线 | 确认应用域名与 cloudflared tunnel 状态 |
| `Client ID and Client Secret must not be empty` | HostShell 配置字段为空 | 补全 GUI 字段或 hosts.json |

## 7. 安全与轮换

- **轮换**：Service tokens 页面对 token 执行 **Rotate**，生成新 Secret（旧 Secret 短暂双活后失效）；HostShell 端更新 `client_secret` 即可
- **吊销**：Revoke 立即失效
- **闲置回收**：可配置 Access 自动禁用长期未使用的 token
- **最小权限**：一个 token 只 Include 到它需要的那一个应用策略（配合 Strict auth）
- **存储**：HostShell 内建议后续走 `storage/keys.rs` 的 KeyRef 安全存储（当前 `hosts.json` 为明文，注意文件权限）

## 8. 与 WebSso（浏览器认证）的关系

Service Token 解决"免浏览器"，但个人用户若不想管长期密钥，仍可用 WebSso（`CF_Authorization` cookie）。浏览器自动化获取（macOS loopback 回调 / iOS `ASWebAuthenticationSession`）见待办，当前 WebSso 需手动粘贴 cookie。
