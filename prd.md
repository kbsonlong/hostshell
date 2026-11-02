# HostShell 移动 SSH 与零信任连接终端 产品需求文档（PRD）

| 项目 | 内容 |
|---|---|
| 产品名称 | **HostShell** |
| 产品全称 | **HostShell 移动 SSH 与零信任连接终端** |
| 应用商店名称 | **HostShell - 移动 SSH 运维终端** |
| 文档版本 | v1.0 |
| 文档状态 | 评审稿 |
| 目标平台 | iOS 16+ / Android 10+ |
| 关联文档 | 《手机端 SSH 客户端技术与产品设计方案》 |
| 核心特性 | ProxyJump 多跳、Cloudflare Access Zero Trust SSH |

---

## 1. 产品概述

### 1.1 背景

移动办公与紧急运维场景下，工程师需要通过手机登录内网服务器。企业服务器通常处于内网隔离环境，连接链路主要有两类：

1. **传统堡垒机 / 跳板机**：基于 OpenSSH `ProxyJump` 或 `ssh -W` 多跳中继。
2. **零信任网关**：以 Cloudflare Access 为代表，通过 `ProxyCommand cloudflared access ssh --hostname %h` 将 SSH 流量封装进带鉴权的 WSS 通道。

现有移动端 SSH 客户端对上述两类链路的支持普遍薄弱：ProxyJump 配置复杂、Cloudflare Access 几乎无法使用、连接失败时缺少分层诊断。HostShell 面向这一空白，提供移动端原生的多跳与零信任 SSH 连接能力。

### 1.2 产品定位

**HostShell** 是一款面向运维工程师、SRE、后端开发者的**移动端专业 SSH 客户端**，在手机沙盒限制下原生支持直连、ProxyJump 多跳、Cloudflare Access 零信任三种链路，并提供清晰的连接阶段可视化与移动端终端交互体验。

### 1.3 产品目标

| 目标 | 说明 |
|---|---|
| G1 可用 | HostShell 在手机端可完成直连、单跳/多跳 ProxyJump、Cloudflare Access SSH 三类连接 |
| G2 可诊断 | 多跳/零信任连接失败时，用户能定位失败层级（鉴权、网络、SSH 认证等） |
| G3 安全 | 私钥与 Token 不出安全存储，支持生物识别确认 |
| G4 移动友好 | 终端键盘辅助栏、后台恢复、弱网重连体验可用 |

### 1.4 成功指标（上线 3 个月）

| 指标 | 目标值 |
|---|---|
| 直连 SSH 连接成功率 | ≥ 98% |
| ProxyJump 连接成功率 | ≥ 95% |
| Cloudflare Access Service Token 连接成功率 | ≥ 95% |
| 连接失败时用户可看到明确失败阶段的比例 | 100% |
| 7 日留存（激活用户） | ≥ 35% |
| 崩溃率 | < 0.5% |

### 1.5 非目标（首版不做）

- SFTP 文件管理（引擎预留，产品首版不暴露）
- SSH Agent Forwarding
- 多窗口分屏终端
- 团队资产共享与云端同步
- 桌面端完整 `~/.ssh/config` 语义（仅支持子集导入）

---

## 2. 用户与场景

### 2.1 目标用户

| 画像 | 特征 | 核心诉求 |
|---|---|---|
| 运维/SRE | 经常处理线上告警，需随时登录服务器 | 快速连接、多跳、连接状态清晰 |
| 后端开发 | 需要查看测试/预发环境日志 | 配置简单、SSO 免密登录 |
| 企业 IT 管理员 | 管理零信任资产 | Service Token 管理、安全合规 |

### 2.2 核心场景

**场景 A：紧急告警处理（ProxyJump）**
> 凌晨收到告警，工程师用手机打开 HostShell，选择已配置的 `prod-k8s-node-01`，该主机通过 `bastion-1 → bastion-2` 两跳接入。HostShell 展示 `[1/3] 跳板机1认证 → [2/3] 跳板机2通道 → [3/3] 目标主机认证`，连接成功后直接执行 `kubectl logs`。

**场景 B：零信任环境登录（Cloudflare Access Service Token）**
> 企业使用 Cloudflare Access 保护 SSH。用户在主机卡片中选择 Cloudflare Access 模式，填入 Client ID / Secret，一键连接，无需浏览器登录。

**场景 C：个人开发者 SSO 登录**
> 用户选择“浏览器登录”，HostShell 弹出内置 WebView 完成 Google/GitHub 登录，自动捕获 `CF_Authorization` Cookie 并连接。

**场景 D：从 PC 迁移配置**
> 用户从剪贴板粘贴 PC 端 `~/.ssh/config` 片段，HostShell 识别 `ProxyJump` 与 `ProxyCommand cloudflared access ssh`，自动生成主机卡片与代理配置。

**场景 E：移动网络切换**
> 地铁中 Wi-Fi 切 5G，连接断开。HostShell 提示“连接已断开”，用户点击“重连”，恢复终端缓冲区与滚动位置。

### 2.3 用户故事（示例）

- 作为运维，我希望在主机卡片上直接看到代理模式标签，以便确认会走哪条链路。
- 作为运维，我希望连接失败时看到失败发生在“Cloudflare 鉴权”还是“SSH 密钥认证”，以便快速判断是 Token 过期还是密钥问题。
- 作为开发者，我希望软键盘上方有 Ctrl/Tab/Esc/方向键，以便在手机上操作 tmux/vim。
- 作为安全管理员，我希望 Service Token 存储在系统安全区，且导出配置时默认脱敏。

---

## 3. 产品范围与版本规划

| 版本 | 范围 | 优先级 |
|---|---|---|
| **MVP** | 直连 SSH、单跳 ProxyJump、Cloudflare Access Service Token、主机卡片、终端+辅助键盘、Keychain/Keystore、阶段状态、known_hosts 首次信任 | P0 |
| **V1.1** | 多跳 ProxyJump、Cloudflare Web SSO、`~/.ssh/config` 导入、后台恢复与一键重连、连接诊断日志 | P1 |
| **V1.2** | 跳板机资产库拖拽排序、生物识别、证书固定、多会话标签 | P1/P2 |
| **V2** | SFTP、团队资产同步 | P2 |

---

## 4. 信息架构与核心流程

### 4.1 信息架构

```
HostShell
├─ 主机列表
│   ├─ 主机卡片（名称/地址/代理模式标签）
│   ├─ 新建/编辑主机
│   └─ 导入配置
├─ 跳板机资产库
│   ├─ 跳板机列表
│   └─ 新建/编辑跳板机
├─ 会话
│   ├─ 终端页面
│   ├─ 连接阶段状态
│   └─ 断开/重连
├─ 设置
│   ├─ 安全（生物识别、known_hosts 管理）
│   ├─ 终端（字体、配色、键盘栏）
│   └─ 诊断日志
└─ 账户/关于
```

### 4.2 核心连接流程

```
选择主机
  → 读取代理模式
  → [直连] TCP 连接
  → [ProxyJump] 逐跳建立 SSH + direct-tcpip 通道
  → [Cloudflare] WSS 握手（Service Token / SSO Cookie）
  → 目标 SSH 握手（Host Key 校验）
  → 用户认证（密码/私钥）
  → 申请 PTY + Shell
  → 进入终端会话
```

任一阶段失败 → 展示失败阶段 + 错误原因 + 可操作建议（重试/编辑配置/重新登录）。

---

## 5. 功能需求

优先级定义：P0 = MVP 必须；P1 = V1.1；P2 = 后续。

### 5.1 主机与资产管理

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-01 | 主机卡片列表 | P0 | 展示名称、地址、用户名、代理模式标签（直连/跳板机/Cloudflare） |
| FR-02 | 新建/编辑主机 | P0 | 字段：名称、Host、Port、Username、认证方式、代理模式 |
| FR-03 | 认证方式 | P0 | 密码、私钥（导入/生成）、密钥+密码 |
| FR-04 | 代理模式三选一 | P0 | 直连 / ProxyJump / Cloudflare AP1+r4632=1B5B32347E\P0+r2531\P0+r2638\P1+r6B62=7F\P0+r6B49\P1+r6B44=1B5B337E\P1+r6B68=1B4F48\P1+r4037=1B4F46\P1+r6B50=1B5B357E\P1+r6B4E=1B5B367E\ccess |
| FR-05 | 跳板机资产库 | P0 | 跳板机可独立创建、复用；主机引用跳板机 |
| FR-06 | 多跳跳板机排序 | P1 | 拖拽排序；环路检测；删除跳板机时提示引用主机 |
| FR-07 | 主机搜索与分组 | P1 | 按名称/标签搜索；分组或收藏 |
| FR-08 | 删除二次确认 | P0 | 删除主机/跳板机需确认 |

**验收标准（FR-01/02/04）**
- 新建主机时若选择 ProxyJump，必须至少选择一个跳板机，否则保存按钮不可用并提示。
- 选择 Cloudflare Access 时，认证方式必须选择 Service Token 或浏览器登录。
- 主机卡片上的代理模式标签与实际连接链路一致。

---

### 5.2 连接配置：ProxyJump

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-10 | 单跳 ProxyJump | P0 | 客户端连接跳板机 → `direct-tcpip` → 目标 SSH 握手 |
| FR-11 | 多跳链式 ProxyJump | P1 | 跳板机 1 → 跳板机 2 → 目标，顺序可配置 |
| FR-12 | 跳板机独立认证 | P0 | 每跳独立用户名/密码/私钥 |
| FR-13 | 跳板机连通性测试 | P1 | 编辑页提供“测试连接”，只测到跳板机认证完成 |
| FR-14 | 内网 DNS 由跳板侧解析 | P0 | 目标 Host 原样传给 `direct-tcpip`，不在本地解析 |
| FR-15 | 环路检测 | P1 | 多跳配置中出现重复跳板机时阻止保存 |

**验收标准**
- 单跳 ProxyJump 连接成功后，目标机 `who` / `last` 显示来源为跳板机而非手机 IP。
- 目标机私钥仅存手机本地，跳板机不接收 Agent Forwarding。
- 多跳配置顺序调整后，连接阶段指示按新顺序展示。

---

### 5.3 连接配置：Cloudflare Access

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-20 | Service Token 模式 | P0 | 输入 Client ID / Client Secret，安全存储 |
| FR-21 | Web SSO 模式 | P1 | 内置 WebView 完成 IdP 登录，捕获 `CF_Authorization` Cookie |
| FR-22 | Token/Cookie 有效期管理 | P1 | 过期前提示；连接失败识别为鉴权失败并引导重新登录 |
| FR-23 | 鉴权信息脱敏展示 | P0 | Secret 默认隐藏，日志与导出配置脱敏 |
| FR-24 | 连接阶段区分 | P0 | 明确区分“Cloudflare 鉴权握手”与“目标 SSH 认证” |
| FR-25 | 自定义 Hostname | P1 | 支持 `--hostname %h` 等价配置，默认取主机 Host |

**验收标准**
- Service Token 正确时可直接建立 WSS 并完成 SSH 握手，全程无浏览器弹窗。
- Service Token 错误时，失败阶段显示“Cloudflare Access 鉴权失败”，并提供“编辑 Token”入口。
- SSO Cookie 过期时，提示“登录已过期”，点击可重新拉起 WebView。
- 导出的主机配置中 Client Secret 与 Cookie 不出现明文。

---

### 5.4 连接建立与阶段状态

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-30 | 阶段式连接状态页 | P0 | 展示当前阶段、已完成阶段、失败阶段 |
| FR-31 | 阶段划分 | P0 | 网络连接 → 代理/跳板 → 网关鉴权 → SSH 握手 → 用户认证 → 打开终端 |
| FR-32 | 失败原因分类 | P0 | 网络不可达、DNS 失败、鉴权失败、Host Key 变更、认证失败、超时 |
| FR-33 | 取消连接 | P0 | 连接中可取消，取消后清理资源 |
| FR-34 | 重试 | P0 | 失败页提供“重试”，保留已有配置 |
| FR-35 | 分阶段超时 | P1 | 各阶段独立超时，避免单阶段长时间卡住 |
| FR-36 | 连接诊断详情 | P1 | 可展开查看脱敏后的阶段日志 |

**验收标准**
- 多跳连接时，状态页逐项展示每一跳状态，例如 `[1/2] 跳板机认证 完成`、`[2/2] 目标主机认证 进行中`。
- 任一阶段失败，界面必须显示失败阶段名称与可读原因，不允许只显示“连接失败”。

---

### 5.5 Host Key 与 known_hosts

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-40 | 首次连接信任确认 | P0 | 展示指纹，用户确认后保存 |
| FR-41 | Host Key 变更告警 | P0 | 强提示，默认阻止连接，需手动确认 |
| FR-42 | known_hosts 管理 | P1 | 设置页可查看/删除已信任主机 |
| FR-43 | 多跳场景逐跳校验 | P1 | 跳板机与目标机分别校验 |

**验收标准**
- 首次连接未确认 Host Key 时不得自动登录。
- Host Key 变更时默认拒绝连接，并提示可能存在中间人风险。

---

### 5.6 终端会话

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-50 | 终端仿真 | P0 | 支持 xterm 常用序列、256 色、UTF-8 |
| FR-51 | 窗口尺寸同步 | P0 | 键盘弹出/旋转时发送 window-change |
| FR-52 | 复制/粘贴 | P0 | 长按选择、系统剪贴板 |
| FR-53 | 终端缓冲区 | P0 | 支持滚动回看，默认 ≥ 5000 行 |
| FR-54 | 字体与字号设置 | P1 | 等宽字体、字号调节 |
| FR-55 | 多会话标签 | P2 | 同时保留多个会话 |
| FR-56 | 断开提示与重连 | P0 | 断线明确提示，支持重连 |
| FR-57 | 后台恢复 | P1 | 回前台恢复缓冲区与滚动位置，重建会话 |

**验收标准**
- `vim`、`tmux`、`htop` 基本可用，方向键与 Ctrl 组合键正常。
- 旋转屏幕后远端 `stty size` 与窗口一致。
- 断线后终端不清屏，保留历史并显示断线提示。

---

### 5.7 移动端键盘辅助栏

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-60 | 固定辅助栏 | P0 | 软键盘上方固定显示 |
| FR-61 | 基础按键 | P0 | `Esc` `Tab` `Ctrl` `Alt` `|` `~` `/` `-` |
| FR-62 | 方向键 | P0 | 上下左右 |
| FR-63 | 组合宏 | P0 | `Ctrl+C` `Ctrl+D` `Ctrl+Z` |
| FR-64 | Ctrl/Alt 粘滞 | P1 | 点击 Ctrl 后下一次按键组合生效 |
| FR-65 | 自定义按键 | P2 | 用户可增删常用键 |

**验收标准**
- 辅助栏在软键盘弹出时不被遮挡，横屏可用。
- 组合宏在远端 shell 中行为与物理键盘一致。

---

### 5.8 配置导入（`~/.ssh/config` 子集）

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-70 | 剪贴板粘贴导入 | P1 | 解析文本并预览生成结果 |
| FR-71 | 识别 Host/HostName/Port/User/IdentityFile | P1 | 生成主机卡片 |
| FR-72 | 识别 `ProxyJump <name>` | P1 | 自动关联跳板机；不存在时提示创建 |
| FR-73 | 识别 `ProxyCommand cloudflared access ssh --hostname %h` | P1 | 自动切换 Cloudflare Access 模式 |
| FR-74 | 不支持项提示 | P1 | 无法识别的 ProxyCommand 明确标记“不支持”，不静默直连 |
| FR-75 | 导入预览与冲突处理 | P1 | 同名主机提示覆盖/跳过/重命名 |
| FR-76 | 本地 TCP 隧道 | P1 | 识别并运行 `LocalForward [bind_address:]port host:hostport` |
| FR-77 | SOCKS5 动态隧道 | P1 | 识别并运行 `DynamicForward [bind_address:]port`，支持 SOCKS5 CONNECT |
| FR-78 | RemoteForward | P1 | 识别 TCP 与 Unix-domain socket 形式的远程转发 |
| FR-79 | Unix-domain socket 隧道 | P1 | 支持 LocalForward 本地/远端 socket 端点以及 RemoteForward 的本地 socket 目标 |

**验收标准**
- 粘贴含 `ProxyJump` 的配置后，生成的主机卡片代理模式为“跳板机”，且引用关系正确。
- 含不支持 `ProxyCommand` 的条目导入后标记为“需手动配置”，不得自动改为直连。
- `LocalForward`、`DynamicForward`、`RemoteForward` 与 streamlocal 规则在导入预览中逐条显示；格式错误的规则进入警告列表。
- 关闭 SSH 会话后，客户端监听端口、本地 Unix socket 和服务端转发请求均清理。
- 默认只监听 loopback；配置显式指定通配地址时才开放到所有接口。

---

### 5.9 安全与密钥管理

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-80 | 私钥与 Secret 安全存储 | P0 | iOS Keychain / Android Keystore |
| FR-81 | 生物识别确认 | P1 | 连接前或查看私钥前可配置 Face ID/指纹 |
| FR-82 | 私钥导入 | P0 | 支持粘贴/文件导入 OpenSSH 私钥 |
| FR-83 | 密钥生成 | P2 | HostShell 内生成 ed25519 密钥 |
| FR-84 | 日志脱敏 | P0 | 不记录密码、私钥、Token、Cookie |
| FR-85 | 导出配置脱敏 | P0 | 导出不含 Secret/Cookie，或需生物识别后导出 |
| FR-86 | 证书固定 | P2 | 企业策略可选开启 |
| FR-87 | 应用锁 | P1 | 启动/回前台需生物识别（可配置） |

**验收标准**
- 在设备文件系统中无法以明文检索到密码、私钥、Client Secret、Cookie。
- 诊断日志中不出现上述敏感字段。
- 开启应用锁后，冷启动必须通过生物识别才能查看主机列表。

---

### 5.10 保活、弱网与后台

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-90 | SSH 心跳 | P0 | 默认 `ServerAliveInterval 15`，可配置 |
| FR-91 | 断线检测与提示 | P0 | 心跳失败后提示断线 |
| FR-92 | 一键重连 | P1 | 重连后重建 PTY，尽量恢复缓冲区 |
| FR-93 | 后台保活 | P1 | iOS Background Task / Android 前台服务（可选） |
| FR-94 | 网络切换处理 | P1 | Wi-Fi/蜂窝切换后提示并支持重连 |
| FR-95 | 重连不重复弹认证 | P1 | 凭据仍有效时自动重试一次 |

**验收标准**
- 飞行模式切换后 30 秒内界面显示断线状态。
- 重连成功后终端历史仍可见，用户可继续输入。
- 不得承诺“后台永久保活”，文案需准确描述为“尽量保持/快速恢复”。

---

### 5.11 设置与诊断

| 编号 | 需求 | 优先级 | 说明 |
|---|---|---|---|
| FR-100 | 终端外观设置 | P1 | 字体、字号、配色 |
| FR-101 | 连接诊断日志 | P1 | 分阶段日志，默认脱敏，可导出 |
| FR-102 | known_hosts 管理 | P1 | 查看/删除 |
| FR-103 | 清除本地数据 | P1 | 清除主机、密钥、日志需二次确认 |
| FR-104 | 关于与开源许可 | P2 | 版本、隐私政策、许可 |

---

## 6. 非功能需求

| 类别 | 要求 |
|---|---|
| 性能 | HostShell 冷启动到主机列表 < 2s；直连首屏终端 < 5s（正常网络）；终端输入回显延迟 < 150ms（4G） |
| 稳定性 | 崩溃率 < 0.5%；连接中取消不泄漏资源；大输出（`cat` 大文件）不 OOM |
| 兼容性 | iOS 16+；Android 10+；支持 IPv4/IPv6；支持常见 SSH 算法（ed25519、RSA-SHA2、ECDSA） |
| 安全 | 敏感信息仅存安全存储；日志脱敏；Host Key 校验；传输使用系统 TLS |
| 可用性 | 连接失败必须给出阶段与原因；关键操作有确认；支持深色模式 |
| 本地化 | 首版简体中文，预留英文 |
| 隐私 | 不采集终端内容；诊断日志需用户主动导出 |

---

## 7. 数据模型（产品视角）

**Host（主机）**
- id、name、hostname、port、username
- authType（password / privateKey）
- credentialRef（指向安全存储的引用，不存明文）
- proxyMode（direct / proxyJump / cloudflare）
- jumpHostIds[]（有序）
- cloudflareConfig：authType（serviceToken / sso）、clientIdRef、secretRef、cookieRef、hostnameOverride
- createdAt、updatedAt、lastConnectedAt

**JumpHost（跳板机）**
- id、name、hostname、port、username、authType、credentialRef

**KnownHost**
- hostname、port、keyType、fingerprint、addedAt

**Session（运行时会话，不持久化敏感数据）**
- hostId、state、currentStage、startedAt、bufferMeta

---

## 8. 埋点与指标

| 事件 | 关键属性 |
|---|---|
| host_created | proxyMode、authType |
| connection_started | proxyMode、jumpCount、cfAuthType |
| connection_stage | stage、result、durationMs |
| connection_failed | failedStage、errorCategory |
| connection_succeeded | totalDurationMs、proxyMode |
| sso_login | idpType、result |
| config_imported | recognizedCount、unsupportedCount |
| session_disconnected | reason（network/timeout/user） |
| reconnect_clicked | success |

**隐私要求**：不上报主机地址、用户名、终端内容、Token；仅上报聚合与错误分类。

---

## 9. 验收标准汇总（关键场景）

| 场景 | 验收条件 |
|---|---|
| 直连 SSH | 密码/私钥登录成功，终端可用，Host Key 首次确认 |
| 单跳 ProxyJump | 经跳板机连接目标成功，失败阶段可区分跳板机/目标 |
| 多跳 ProxyJump | 两跳以上顺序正确，支持拖拽调整与环路拦截 |
| CF Service Token | 无浏览器弹窗直连成功；错误 Token 提示鉴权失败 |
| CF Web SSO | WebView 登录后自动连接；Cookie 过期可重新登录 |
| 配置导入 | `ProxyJump` 与 `cloudflared` 规则正确识别，不支持项不静默降级 |
| SSH 隧道与 Socket | LocalForward / SOCKS5 DynamicForward / TCP 与 Unix socket RemoteForward 按规则转发，断开会话后监听和远端请求被清理 |
| 移动键盘栏 | Esc/Tab/Ctrl/方向键/组合宏在 vim/tmux 中可用 |
| 断线重连 | 断线提示明确，重连后历史保留 |
| 安全 | 敏感信息不明文落盘；日志脱敏；应用锁可用 |

---

## 10. 风险、依赖与开放问题

### 10.1 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| Cloudflare Access WSS 协议细节与预期不符 | 核心特性无法落地 | 先做 PoC 抓包验证，抽象 Transport 插件 |
| iOS 后台限制导致长连接不可持续 | 用户体验落差 | 文案准确，做快速重连与缓冲区恢复 |
| WebSocket/SSH 背压处理不当 | 大流量 OOM | 限制缓冲、异步背压、压力测试 |
| SSO Cookie 捕获的合规问题 | 企业拒绝 | 默认推荐 Service Token；Cookie 加密存储、及时清理 |
| `~/.ssh/config` 解析兼容性 | 导入失败 | 只承诺子集，明确提示不支持项 |
| 企业 SSH 算法兼容 | 连接失败 | 建立算法测试矩阵 |

### 10.2 依赖

- Rust/russh 核心库与移动端绑定
- 终端仿真库（libvterm / Xterm.js 方案选型）
- Cloudflare Access 协议 PoC 结论
- iOS Keychain / Android Keystore 封装

### 10.3 开放问题

1. Cloudflare Access 的 WSS 握手路径、子协议、错误码是否已通过 PoC 确认？
2. 首版是否必须支持多跳，还是单跳即可满足多数用户？
3. Web SSO 是否默认开启，还是企业版才开放？
4. 是否允许导出含私钥的配置（建议默认禁止）？
5. 终端仿真库最终选型与性能基线？

---

## 11. 品牌与命名说明

| 项 | 内容 |
|---|---|
| 英文品牌名 | HostShell |
| 产品全称 | HostShell 移动 SSH 与零信任连接终端 |
| 应用商店名称 | HostShell - 移动 SSH 运维终端 |
| 命名含义 | “Host” 对应主机资产与目标服务器，“Shell” 对应 SSH 终端与命令交互；品牌突出“面向主机的移动 Shell 入口”，不局限单一协议 |
| 使用规范 | 正式文案统一使用 “HostShell”，不加中文品牌名 |
| 发布前检查项 | 商标第 9/42 类、App Store / Google Play 重名、`hostshell.com` 等域名与 GitHub 组织名可用性 |

**风险提示**：HostShell 与既有 HopShell 拼写接近，需确认无商标与商店重名冲突；若被占用，优先降级备选为 **RelayDeck** 或 **JumpTerm**。

---

## 12. 发布计划（建议）

| 阶段 | 内容 | 周期 |
|---|---|---|
| M0 | Cloudflare Access WSS PoC、Transport 背压验证、终端库选型 | 2 周 |
| M1 | 直连 SSH + 主机卡片 + 终端 + 辅助键盘 + 安全存储 | 4 周 |
| M2 | 单跳 ProxyJump + 阶段状态 + Host Key 校验 | 3 周 |
| M3 | CF Service Token + 诊断日志 + 内测 | 3 周 |
| M4 | 多跳、Web SSO、配置导入、后台恢复 | 4 周 |
| M5 | 公测与修复 | 2 周 |

---
