# 手机端 SSH 客户端技术与产品设计方案
> **核心特性**：支持 ProxyJump（跳板机跳转）与 ProxyCommand（重点支持 Cloudflare Access Zero Trust SSH）

---

## 1. 概述与设计背景

在移动办公与紧急运维场景下，工程师常需要通过手机登录内网服务器排查问题。现实中，企业服务器通常处于内网隔离环境，连接链路存在两类典型场景：
1. **传统堡垒机 / 跳板机 (Bastion Host)**：基于 OpenSSH `ProxyJump` 或 `ssh -W` 进行多跳中继。
2. **现代零信任网关 (Zero Trust / Cloudflare Access)**：基于 `ProxyCommand cloudflared access ssh --hostname %h`，底层将 SSH 流量封装于带鉴权的 WebSocket 安全通道。

本方案专为 iOS / Android 移动端设计，旨在兼顾**便携易用性**、**协议兼容性**与**移动端网络/安全特性**。

---

## 2. 系统核心架构与技术实现

移动平台受限于沙盒（Sandbox）隔离机制，无法像桌面端一样调用系统内置命令或随意 `fork()/exec()` 外部二进制程序（如编译后的 `cloudflared` 二进制）。因此，系统采用**“内置协议模拟 + 统一字节流抽象”**的架构设计。

### 2.1 整体架构拓扑

```
┌────────────────────────────────────────────────────────┐
│                   UI 层 (SwiftUI / Jetpack Compose)     │
│   - 主机与跳板机卡片配置                                 │
│   - Cloudflare SSO Web 弹窗鉴权                         │
│   - 移动端虚拟终端交互栏 (Ctrl/Alt/Esc/Tab)              │
├────────────────────────────────────────────────────────┤
│                   终端仿真引擎 (libvterm / Xterm.js)     │
├────────────────────────────────────────────────────────┤
│                   跨平台核心层 (Rust / russh)            │
│  ┌──────────────────────────────────────────────────┐  │
│  │             SSH Protocol Engine                  │  │
│  │  (Session Management, Auth, PTY, Shell, SFTP)    │  │
│  └────────────────────────▲─────────────────────────┘  │
│                           │ 注入 AsyncRead + AsyncWrite │
│  ┌────────────────────────┴─────────────────────────┐  │
│  │             Transport Pipeline Manager           │  │
│  │                                                  │  │
│  │  [模式 A: 直连]                                   │  │
│  │   └─ Standard TCP Stream                         │  │
│  │                                                  │  │
│  │  [模式 B: ProxyJump (跳板机)]                      │  │
│  │   └─ Bastion SSH Session                         │  │
│  │       └─ direct-tcpip Channel (包装为 Stream)    │  │
│  │                                                  │  │
│  │  [模式 C: Cloudflare Access ProxyCommand]         │  │
│  │   └─ WSS Stream (带 Service Token / SSO Cookie)  │  │
│  │       └─ ws-stream 适配器 (包装为 Stream)         │  │
│  └──────────────────────────────────────────────────┘  │
├────────────────────────────────────────────────────────┤
│          系统安全存储 (iOS Keychain / Android Keystore) │
└────────────────────────────────────────────────────────┘
```

---

## 3. ProxyJump（跳板机嵌套）实现细节

### 3.1 协议机制
遵循 RFC 4254 标准，客户端连接第一跳跳板机并通过鉴权后，向跳板机发送 `SSH_MSG_CHANNEL_OPEN`，类型为 `direct-tcpip`：
* `host_to_connect`: 目标内网服务器 IP 或域名。
* `port_to_connect`: 目标端口（通常为 22）。

跳板机会建立到目标机器的 TCP 链路，并将该通道包装为双向数据流。客户端在此通道上发起对目标服务器的二次 SSH 握手（Inner SSH Handshake）。目标机的私钥始终保留在手机本地，不经过跳板机，无需开启高风险的 SSH Agent Forwarding。

### 3.2 多跳支持
支持链式递归调用：
$$\text{Client} \xrightarrow[\text{SSH}]{\text{TCP}} \text{Bastion 1} \xrightarrow[\text{direct-tcpip}]{} \text{Bastion 2} \xrightarrow[\text{direct-tcpip}]{} \text{Target Host}$$

---

## 4. Cloudflare Access SSH (`ProxyCommand`) 专项目标实现

在桌面端，用户在 `~/.ssh/config` 中配置：
```ssh
Host my-server.company.com
    ProxyCommand cloudflared access ssh --hostname %h
```

### 4.1 协议逆向与移动端落地策略
移动端**无需打包安装庞大的 `cloudflared` 二进制**，直接基于其底层标准协议（WebSocket Secure, WSS）原生实现：

1. **连接建立**：发起 `wss://my-server.company.com/` 的 WebSocket 握手。
2. **鉴权透传**（支持两种企业常见方式）：
   * **Service Token（推荐移动端，长期稳定免登录）**：
     在 WSS 握手 Header 中携带：
     ```http
     CF-Access-Client-Id: <client-id>
     CF-Access-Client-Secret: <client-secret>
     ```
   * **Web SSO 鉴权（个人用户，企业 IdP 登录）**：
     App 调起内置轻量 WebView（如 iOS WKWebView / Android CustomTabs）访问目标域名完成 Okta / Google / GitHub 登录，捕获返回的 `CF_Authorization` Cookie，握手时注入 Header：
     ```http
     Cookie: CF_Authorization=<jwt_token>
     ```
3. **数据管道转换**：
   WebSocket 连接成功后，将其作为二进制消息传输管道，使用适配层（如 `ws_stream_tungstenite`）将其适配为 `AsyncRead + AsyncWrite` 字节流，直接作为目标 SSH Session 的传输底层。

---

## 5. UI 与产品交互设计

### 5.1 主机卡片与代理设置 (UI 模块)
* **常规连接配置**：名称、IP/域名、端口、用户名、密码/私钥。
* **代理模式选择（三选一）**：
  1. **直连 (Direct)**。
  2. **ProxyJump（跳板机）**：
     * 从预设跳板机资产库中挑选跳板机（支持按拖拽顺序配置多跳）。
  3. **Cloudflare Access (Zero Trust)**：
     * 认证方式：Service Token（填入 Client ID 与 Secret）或 浏览器登录（一键 SSO 弹窗并自动保存 Token）。
* **专家模式（~/.ssh/config 导入）**：
  * 支持直接从剪贴板粘贴 PC 端配置。
  * 识别到 `ProxyJump <name>` 自动关联跳板机。
  * 识别到 `ProxyCommand cloudflared access ssh --hostname %h` 自动切为 Cloudflare Access 模式。

### 5.2 阶段式连接状态可视化
连接多跳/网关时提供清晰的加载阶段指示：
```
[ 目标: k8s-node-01 ]
  ├─ [1/2] Cloudflare Access 鉴权握手 ...... [ 完成 ]
  └─ [2/2] 目标主机 SSH 密钥认证 ........... [ 进行中... ]
```
如遇网络阻断或 Token 失效，能精准指示失败发生的层级。

### 5.3 移动端专属键盘辅助栏
在系统软键盘上方固定快捷操作栏：
* `Esc`, `Tab`, `Ctrl`, `Alt`, `|`, `~`, `/`, `-`
* 方向键：`↑`, `↓`, `←`, `→`
* 常用组合宏：`Ctrl + C`, `Ctrl + D`, `Ctrl + Z`

---

## 6. 安全、保活与移动网络优化

1. **安全与硬件级密钥隔离**：
   * 优先支持系统级 Secure Enclave (iOS) / StrongBox Keymaster (Android) 派生非对称密钥。
   * 私钥调用与连接操作前，可配置触发 Face ID / 指纹生物识别确认。
2. **移动网络切换与保活 (Keepalive)**：
   * 启用 SSH 底层心跳检测（`ServerAliveInterval 15`），及时探测链路断开。
   * 进入后台时申请 Background Task 延长生命周期；会话休眠后保存终端屏幕缓冲区历史，回到前台支持一键重连并自动恢复屏幕。
3. **远程 DNS 解析保护**：
   * 在使用 ProxyJump 或 Cloudflare Access 时，所有内网域名统一由网关/跳板侧进行 DNS 解析，避免手机本地无法解析内网域名或内网 DNS 泄露。
