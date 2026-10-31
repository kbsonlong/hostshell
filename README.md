# HostShell

<img src="assets/hostshell-logo.svg" alt="HostShell logo" width="96" />

**HostShell** 是一款面向运维工程师 / SRE / 后端开发者的跨端 SSH 客户端，核心是一个纯 Rust 实现的连接内核（`hostshell-core`），上层提供 macOS 桌面 App（SwiftUI）、iOS App（SwiftUI）与终端 CLI 三种形态。

在手机 / 桌面沙盒限制下原生支持三类连接链路：

- **Direct** 直连
- **ProxyJump / 堡垒机** 多跳中继（单跳 / 多跳）
- **Cloudflare Access 零信任** SSH（`cloudflared access` WSS 通道封装）
- **ProxyCommand** 任意自定义代理命令（支持 `%h` / `%p` 占位符）

连接失败时提供分层诊断（网络 → 鉴权 → SSH 认证），私钥与 Token 不出安全存储。

## 项目结构

```
hostshell/
├── crates/
│   ├── hostshell-core/     # Rust 连接内核（workspace 核心库）
│   │   └── src/
│   │       ├── ssh/        # SSH 会话、handler、内建 ssh-agent（AppAgent）
│   │       ├── transport/  # direct / bastion / cloudflare / proxy_command / ws_adapter
│   │       ├── storage/    # 配置存储、ssh-config 导入、密钥管理（keys.rs）
│   │       ├── model/      # Host / JumpHost / KnownHost / ConnectionStage 模型
│   │       └── ffi/        # 供 Swift 端调用的 FFI（C ABI）
│   └── hostshell-cli/      # 终端 CLI（raw mode 交互式会话）
├── apps/
│   ├── macos/              # macOS SwiftUI 桌面客户端（.app 打包见 scripts/build_macos.sh）
│   └── ios/                # iOS SwiftUI 客户端（模拟器构建见 scripts/build_ios.sh）
└── scripts/                # 构建 / 回归脚本
```

## 核心特性

- **多链路连接**：Direct / ProxyJump（多跳）/ Cloudflare Access 零信任 / ProxyCommand
- **认证方式**：password、private key、ssh-agent（`SSH_AUTH_SOCK` 自动发现 + 存活探测）、saved key（`KeyRef` 安全引用）
- **内建 ssh-agent**：`AppAgent` 提供策略可控的 in-app agent server（RequestKeys/Sign 默认放行，AddKeys 可关闭）
- **ssh-config 导入**：解析 `~/.ssh/config`，自动物化 JumpHost 资产
- **连接阶段可视化**：`ConnectionStage` 分阶段上报，失败可定位层级
- **跨端复用**：同一 Rust 内核同时驱动 CLI、macOS、iOS

## 快速开始

### CLI

```bash
# 编译 CLI（或直接运行 scripts/build_cli.sh）
cargo build --release -p hostshell-cli

# 基本用法
./target/release/hostshell-cli list                    # 列出已配置主机
./target/release/hostshell-cli import ~/.ssh/config    # 导入 ssh config
./target/release/hostshell-cli add myserver \
    --host 10.0.0.1 --user ubuntu --port 22 \
    --identity-file ~/.ssh/id_ed25519 \
    --jump bastion                                     # 经堡垒机多跳
./target/release/hostshell-cli connect myserver        # 交互式连接

# 调试
RUST_LOG=info ./target/release/hostshell-cli connect myserver
```

### macOS App

```bash
./scripts/build_macos.sh    # 构建 Rust core + Swift 客户端，产出 target/HostShell.app
```

### iOS App（模拟器）

```bash
./scripts/build_ios.sh
```

### 测试

```bash
cargo test -p hostshell-core
./scripts/check_regression.sh   # 跨客户端回归基线检查
```

## 环境要求

- Rust（stable，edition 2021 workspace，依赖 `russh 0.65` / `tokio`）
- macOS 13+（桌面 App）；iOS 16+（移动端）
- Swift 工具链（`swift build`，SwiftPM）

## 文档

- `prd.md` — 产品需求文档（移动 SSH 与零信任连接终端）
- `mobile_ssh_proxy_design.md` — 移动端代理链路技术设计
- `REGRESSION.md` — 回归测试基线说明
