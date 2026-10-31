# iPhone 免费证书自动续签方案（免手动安装）—— 参考 Sideloop

> 背景：HostShell iOS 通过免费 Apple ID 侧载（Xcode 免费签名 / Sideloadly 等），签名 **7 天过期**，过期后 app 无法打开，需连 Mac 手动重签。本文档分析 [filippofinke/sideloop](https://github.com/filippofinke/sideloop) 的实现机制，给出可落地的全自动续签方案。

---

## 1. 问题定义

| 项目 | 现状 | 痛点 |
| --- | --- | --- |
| 签名方式 | 免费 Apple ID 个人开发者签名 | 签名有效期仅 **7 天**（付费账号为 1 年） |
| 过期后果 | app 启动即闪退 | 必须连 Mac 重签，忘记续签就断档 |
| 重签方式 | Xcode / Sideloadly 重装 | 流程手动；传统 AltStore 需在设备上常驻一个"宿主 app"，占用免费账号仅有的 3 个 App ID 名额 |
| 数据保留 | 同 bundle id 原地覆盖安装可保留数据 | 担心卸载重装丢数据 |

**"免安装"的准确含义**：不是不安装，而是 **无人值守的自动原地覆盖安装（in-place reinstall）** —— bundle id 不变，iOS 把它当作更新而非新装，**app 数据（Documents/Keychain/UserDefaults）全部保留**。用户全程无感，等价于"app 自己把证书续了"。

## 2. Sideloop 核心机制

Sideloop 是一个自托管服务（Python 标准库实现，无第三方依赖，单 Docker 镜像，amd64/arm64 双架构），核心思路：

1. **服务端常驻**：在一台局域网内的 Linux 机器或 Mac 上跑一个 Docker 服务，持有 Apple ID 凭证和 IPA。
2. **Wi-Fi 直连设备**：通过 `usbmuxd`/`netmuxd` + `libimobiledevice` 走 Apple 私有 lockdownd 协议，USB 或 Wi-Fi 均可触达设备（iPhone 在"访达"勾选 *Show this iPhone when on Wi-Fi* 后，Wi-Fi 也能安装）。
3. **到期探测不靠猜**：`ideviceprovision copy` 把设备上的 provisioning profiles 拉回来，`openssl smime -verify` 解出 plist 读 `ExpirationDate` 和签名证书 SHA1，精确知道还剩几天、是不是自己签的（跳过 SideStore/Xcode 签的 profile）。
4. **到期前自动重签**：默认 `RENEW_BEFORE_DAYS=2`，剩余 ≤2 天或设备上线（watcher 收到设备 arrival 事件，5 分钟 debounce）时触发；每次运行前 `flock` 串行化。
5. **原地安装保数据**：调用打过补丁的 `AltServer-Linux` 完成签名 + 安装，`timeout 2400` 硬超时。

### 2.1 组件拓扑

```
┌─ Docker host (LAN) ─────────────────────────────────────┐
│  sideloop app (Python stdlib, :8080 Web UI)             │
│    ├─ watcher.py   周期巡检(30min) + 设备上线 poke       │
│    ├─ refresh.sh   到期探测 → AltServer 签名安装         │
│    ├─ AltServer-Linux (patched)   签名 + 原地安装        │
│    ├─ netmuxd v0.4.3  网络 usbmuxd（Wi-Fi 可达设备）     │
│    └─ libimobiledevice (idevice_id/info/provision)      │
│  anisette-v3-server (Dadoum)   自托管 Apple 验证数据     │
│    └─ 伪造 iTunes 客户端 anisette headers，绕过官方服务器 │
└──────────────┬──────────────────────────────────────────┘
               │ usbmuxd (USB) / Wi-Fi + lockdownd
        ┌──────▼──────┐
        │  iPhone(s)  │  HostShell.ipa（数据保留，无感续签）
        └─────────────┘
```

### 2.2 三个关键补丁/细节（Stock AltServer 的坑）

这些是该项目最有价值的工程经验，任何自研方案都会踩：

1. **`ALTSERVER_KEEP_PROFILES=1`**：原版 AltServer 安装前会**删掉设备上所有免费 provisioning profile**，装完再恢复 —— 一旦中途失败/超时，其它侧载 app 的 profile 丢了，iOS 直接报 "Untrusted Developer"（签名其实还有效）。补丁让安装过程不删 profile，事后由 `prune_profiles` 只删被新 profile 取代的旧 profile（同 team 内每个 bundle id 保留最新一个），保证 developer trust 不掉。
2. **证书缓存 `data/AltServerData/`**：AltServer 缓存签名证书于此。缓存丢失会导致**换发新证书**，iOS 要求重新信任开发者。同时若 Apple ID 同时被 Xcode/AltStore/SideStore 使用导致证书变更，`save_probe` 会告警提示需重新 Trust。
3. **`heal_siblings` 自愈**：每次成功安装后复查设备上其它 app 的 profile，发现丢失的清除本地记录、下轮重装，解决中途失败连坐问题。

### 2.3 触发逻辑（watcher.py）

- 巡检间隔：有 app 临期 → 30 min；全部安全 → 6 h；启动后 2 min 先跑一次。
- 设备上线事件（USB 插入或 Wi-Fi 出现）→ 入队，5 min debounce 后立即尝试。
- 设备不可达（锁屏/休眠/不在同一 Wi-Fi）→ 记录 offline，不计数失败，下轮重试。
- 2FA：Apple ID 首次登录要求 2FA 验证码，在 Web UI 输入一次；之后同一证书登录静默通过。

## 3. 部署指南

### 3.1 前置条件

- 一台常开的局域网机器（Linux amd64/arm64 或 Mac），已装 Docker + Compose
- 一个**一次性 Apple ID**（建议专门注册，勿用主力账号）
- HostShell.ipa（`scripts/build_ios.sh` 产出 xcframework 后，Xcode `Product > Archive > Export` 得到，或 `xcodebuild -exportArchive`）

### 3.2 Linux 部署（推荐，家用服务器/NAS）

```bash
git clone https://github.com/filippofinke/sideloop.git
cd sideloop
cp .env.example .env          # TZ=Asia/Shanghai
docker compose up -d          # 首次构建 AltServer 源码，需几分钟
```

打开 `http://<host>:8080` 设置密码 → USB 连接 iPhone 完成配对（访达/Finder 里信任）→ 上传 IPA → 填 Apple ID（**普通密码**，App-specific password 无效）→ 首次安装输入 2FA 验证码。

小设备（如 Raspberry Pi 3）建议交叉构建镜像再拷贝：

```bash
docker build --platform linux/arm64 -t sideloop .
docker save sideloop | gzip | ssh pi@<host> 'gunzip | docker load'
ssh pi@<host> 'cd sideloop && docker compose up -d --no-build'
```

### 3.3 macOS 部署（Docker Desktop）

macOS 的 Docker 看不到 USB/Wi-Fi 设备，先用 `socat` 把宿主机 usbmuxd 桥接进容器：

```bash
brew install socat
socat TCP-LISTEN:27015,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/var/run/usbmuxd &
docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d
```

macOS overlay 把容器改为 `MUX=external` + `USBMUXD_SOCKET_ADDRESS=host.docker.internal:27015`，端口仅绑 `127.0.0.1:8080`。

> 也可以在 Mac mini 上直接原生跑（不套 Docker）：安装 `libimobiledevice`（`brew install libimobiledevice`）+ 补丁版 AltServer，直接调用 `scripts/refresh.sh`，用 launchd 定时触发。省去 usbmuxd 桥接，链路最短。

### 3.4 iPhone 端设置

1. **设置 > 通用 > VPN与设备管理**：首次安装后信任开发者（仅一次；Sideloop 的补丁保证后续刷新不掉信任）。
2. **访达（Finder）**：连接 iPhone，勾选 **"连接此 iPhone 时显示"（Show this iPhone when on Wi-Fi）**——Wi-Fi 续签的前提。
3. 设备保持解锁且与服务器在同一 Wi-Fi 时才会执行安装；锁屏也可触发"上线"但中途锁屏会导致安装失败重试。

### 3.5 人工触发/排障

```bash
docker exec -it sideloop /usr/local/bin/refresh.sh --recheck            # 重新探测设备上的真实到期时间
docker exec -it sideloop /usr/local/bin/refresh.sh --force              # 立即强制重签
docker exec -it sideloop /usr/local/bin/refresh.sh --device <udid>      # 只处理某台设备
tail -f data/state/refresh.log                                          # 运行日志
```

数据全部落在 `./data/`：`apps/<id>/{app.ipa,meta.env,state/<udid>/{expiry,certificate,consecutive_failures}}`、`devices/<udid>.env`、`state/refresh.log`。备份 `./data` 即备份全部状态。

## 4. 约束与限制（免费 Apple ID）

- 每设备最多 **3 个侧载 app**；每 7 天最多注册 **10 个 App ID**；**每个 App Extension 独占一个 App ID**（HostShell 无扩展，无影响）。
- 必须使用 Apple ID **普通密码**（anisette 走的是 iTunes 登录链路，不支持 app-specific password）。
- 首次登录需输 2FA 验证码；之后静默。
- 安装窗口期设备必须解锁、同 Wi-Fi。
- Apple 风控随时可能变更接口：签名失效时更新 `Dockerfile` 里的 `ALTSERVER_TAG`（当前 `ng-2026-09-13`）并重建。
- 主 bundle id 必须保持不变，否则 iOS 视为新 app，数据丢失。

## 5. 与 HostShell 的结合建议

1. **产物**：`scripts/build_ios.sh` 产出 `HostShellCore.xcframework` 后，Xcode archive 导出未签名/开发签名 IPA 交给 Sideloop 统一签名发布，IPA 版本号递增、bundle id 固定为 `com.hostshell.ios`。
2. **更新流**：改代码 → 导出新 IPA → Sideloop Web UI 上传替换 `app.ipa` → 下一轮刷新自动带上新版本，无需单独装。
3. **兜底监控**（可选）：cron 每 6 h `ideviceprovision`/`refresh.sh --recheck` 解析 `data/apps/*/state/*/expiry`，剩余 <3 天且设备长期离线时推 Telegram 告警，复用现有 `~/.hermes/scripts/gz/` 的推送链路。
4. **多 app 复用**：同一服务器可同时托管其它侧载 IPA（如 dsh-tg 相关调试包），共享 3 App ID 名额需规划。

## 6. 备选方案对比

| 方案 | 设备端常驻 | 数据保留 | 自动化 | 备注 |
| --- | --- | --- | --- | --- |
| **Sideloop（本文方案）** | 无 | ✅ 原地重装 | ✅ 全自动（Wi-Fi） | 需一台常开服务器 |
| AltStore | ✅ 需装 AltStore | ✅ | 半自动（需开 AltStore 刷新） | 占 1 个 App ID；夜间充电+同 Wi-Fi 才刷 |
| SideStore | ✅ 需装 SideStore | ✅ | ✅（配合 VPN 式本地回环） | 占 1 个 App ID；SideStore 证书链路独立，与其它工具混用易互相踢 profile |
| Sideloadly + cron | 无 | ✅ | 半自动 | 仍需 Mac 常驻 + USB/Wi-Fi，无到期探测 |
| Xcode 手动重签 | 无 | ✅ | ❌ 纯手动 | 现状 |
| 付费 Apple Developer ($99/年) | 无 | ✅ | ✅ 一次签名 1 年 | 一劳永逸，若侧载需求长期存在可评估 |

## 7. 安全注意

- **Apple ID 普通密码明文存于服务端**（`data/config.env`）：务必只在内网部署，Web UI 端口绑 `127.0.0.1` 或防火墙限制；这也是强烈建议用一次性 Apple ID 的原因。
- 自托管 anisette 服务器避免第三方 anisette 窥探登录数据，但 Apple 风控对伪造 anisette 有封号风险（免费小号可接受，主力号勿用）。
- `docker-compose.yml` 默认 `network_mode: host` + `privileged: true`（Linux 需要 udev/usb 直通）；不信任时可改用 mac 版的端口映射形态，牺牲 Wi-Fi 支持换隔离。
- 项目 MIT 协议，与 Apple 无关联；Apple 条款上个人免费签名仅限自用，勿分发签名包给他人。

## 8. 参考

- Sideloop: https://github.com/filippofinke/sideloop （MIT）
- AltServer-Linux (patched fork): https://github.com/jaakkopalvaila/AltServer-Linux
- anisette-v3-server: https://github.com/Dadoum/anisette-v3-server
- netmuxd: https://github.com/jkcoxson/netmuxd
- libimobiledevice: https://libimobiledevice.org
