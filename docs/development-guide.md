# HostShell 开发指南

本文从 GitHub 获取源码开始，覆盖 Rust/CLI、macOS 和 iOS 三条开发、构建与验证路径。命令默认在仓库根目录执行；编译产物位于已忽略的 `target/`、各应用 `.build/` 或生成的 `apps/ios/Frameworks/HostShellCore.xcframework`。

## 1. 从 GitHub 获取源码

首次克隆（SSH，需要 GitHub SSH key）：

```sh
git clone git@github.com:kbsonlong/hostshell.git
cd hostshell
git switch main
git pull --ff-only origin main
```

如果当前网络不能使用 SSH，可改用 HTTPS：

```sh
git clone https://github.com/kbsonlong/hostshell.git
cd hostshell
git switch main
git pull --ff-only origin main
```

已有工作区更新前先检查本地改动：

```sh
git status --short --branch
git fetch origin
git switch main
git pull --ff-only origin main
```

如果工作区有未提交改动，先自行提交或妥善保存，再更新分支。`--ff-only` 会在不能快进时停止，避免 pull 自动生成合并提交。

## 2. 环境准备

完整构建需要 macOS、Xcode Command Line Tools、Swift、Rust stable 和 GitHub 网络访问。客户端最低系统版本为 macOS 13 和 iOS 16。iOS 模拟器运行还需要在 Xcode 中安装一个 iOS Simulator Runtime。

检查工具链：

```sh
xcode-select -p
xcodebuild -version
swift --version
rustup show
rustup run stable rustc -vV
```

Rust workspace 使用 edition 2021。macOS 和 iOS 客户端通过 Swift Package Manager 依赖 SwiftTerm；根目录 `Cargo.lock`、`apps/macos/Package.resolved` 和 Xcode 工程的 `Package.resolved` 固定了已解析的依赖版本。

### Xcode 包解析

首次打开 iOS 工程，或看到 `Package resolution errors must be fixed before building` 时，先解析 Swift 包，再构建：

```sh
xcodebuild -resolvePackageDependencies \
  -project apps/ios/HostShellIOS.xcodeproj
```

Xcode 图形界面中可打开工程，选择 **File → Packages → Resolve Package Versions**。本仓库当前锁定 SwiftTerm 1.2.5；解析失败时先确认网络可以访问 GitHub，并检查对应 `Package.resolved` 是否存在，再重试解析。

## 3. 路径一：Rust core 与 CLI

### 编译与测试

```sh
cargo test --workspace --locked
cargo build --release --locked -p hostshell-core
cargo build --release --locked -p hostshell-cli
```

也可使用 CLI 构建脚本，它会编译 CLI 并打印帮助信息：

```sh
./scripts/build_cli.sh
```

CLI 二进制位于 `target/release/hostshell-cli`。可用 `--help` 查看命令：

```sh
./target/release/hostshell-cli --help
```

`cargo test --workspace --locked` 覆盖 workspace 中的 core 和 CLI 测试。需要单独检查格式时运行：

```sh
cargo fmt --all -- --check
```

当前 `scripts/check_regression.sh` 没有调用 rustfmt；格式检查需单独执行。`REGRESSION.md` 描述的回归步骤若与脚本实际内容不同，以脚本当前执行的命令为准。

### CLI 本地使用

常用命令包括：

```sh
./target/release/hostshell-cli list
./target/release/hostshell-cli import ~/.ssh/config
./target/release/hostshell-cli list-jumps
./target/release/hostshell-cli connect <host-name>
```

手工执行 `import` 会写入当前用户的配置目录。回归脚本会使用临时 `HOME` 和 `XDG_CONFIG_HOME`，避免读取或修改开发者自己的 SSH 配置；手动验证时也建议使用临时目录。

## 4. 路径二：macOS 桌面应用

在仓库根目录构建：

```sh
./scripts/build_macos.sh
```

脚本依次编译 Rust `hostshell-core`、使用 SwiftPM 编译 SwiftUI 客户端，并打包 `target/HostShell.app`。启动应用：

```sh
open target/HostShell.app
```

构建脚本会在检测到 `~/.cargo/bin/rustup` 时把 rustup 工具链放到 PATH 前面。这样可以避免误用 Homebrew 的 Rust/LLVM 组合。

### Rust 工具链故障排查

如果 Rust 编译器在 `rustc -vV` 阶段退出，并报错类似：

```text
Library not loaded: /opt/homebrew/opt/z3/lib/libz3.4.15.dylib
Referenced from: .../libLLVM.dylib
```

这是 Homebrew Rust/LLVM 与当前 Z3 dylib 版本不匹配，不是 Rust crate 编译错误。先检查 rustup 工具链：

```sh
rustup run stable rustc -vV
```

本仓库的 `build_macos.sh` 会优先选用已安装的 rustup。手动运行 Cargo 命令时也可显式调整 PATH：

```sh
PATH="$HOME/.cargo/bin:$PATH" cargo build --release -p hostshell-core
```

## 5. 路径三：iOS 应用

### 5.1 构建 Rust XCFramework

从仓库根目录执行：

```sh
./scripts/build_ios.sh
```

脚本会用 rustup 为 iOS device 和 iOS simulator 编译 `hostshell-core`，再生成：

```text
apps/ios/Frameworks/HostShellCore.xcframework
```

这个 XCFramework 在 `.gitignore` 中；新克隆后要先运行该脚本，再构建 Xcode 客户端。脚本会重建这个生成目录。

### 5.2 解析 Swift 包并构建模拟器 App

先解析 Xcode 工程依赖，再以 arm64 架构构建：

```sh
xcodebuild -resolvePackageDependencies \
  -project apps/ios/HostShellIOS.xcodeproj

xcodebuild -project apps/ios/HostShellIOS.xcodeproj \
  -scheme HostShellIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/hostshell-ios-derived \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build
```

构建产物位于：

```text
/tmp/hostshell-ios-derived/Build/Products/Debug-iphonesimulator/HostShellIOS.app
```

当前 XCFramework 提供 iOS device arm64 和 iOS simulator arm64 切片，没有 x86_64 simulator 切片。若构建尝试链接 x86_64 并报 `Undefined symbols for architecture x86_64`，使用上面的 arm64 构建设置；若需要 Intel 模拟器支持，必须先为 Rust core 增加 x86_64 simulator 切片并重新生成 XCFramework。

### 5.3 在模拟器运行

列出已安装的模拟器并选择一个 UDID：

```sh
xcrun simctl list devices available
```

启动、安装并运行：

```sh
SIMULATOR_ID="<上一步列出的 UDID>"
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" \
  /tmp/hostshell-ios-derived/Build/Products/Debug-iphonesimulator/HostShellIOS.app
xcrun simctl launch "$SIMULATOR_ID" com.hostshell.ios
```

首次启动的模拟器可能需要完成系统迁移，`bootstatus` 会等待迁移结束。若 CoreSimulatorService 不可用，先检查 Xcode 是否安装了该设备对应的 runtime，再重新启动 Simulator/Xcode。

在 Xcode 中运行时，打开 `apps/ios/HostShellIOS.xcodeproj`，先执行包解析，选择 `HostShellIOS` scheme 和 arm64 iPhone/iPad 模拟器，再点 Run。真机运行还需要有效的 Apple Developer 签名配置；`build_ios.sh` 只负责 Rust 库和 XCFramework，不负责设备签名。

## 6. 三路回归验证

完整本地回归入口：

```sh
./scripts/check_regression.sh
```

脚本当前实际执行：

1. Rust workspace 测试：`cargo test --workspace --locked`。
2. CLI release 编译和隔离的 SSH config 导入、列表、重复导入 smoke test。
3. macOS 与 iOS Swift wire model 合约检查。
4. macOS Release App 构建。
5. iOS device/simulator Rust XCFramework 构建。
6. 指定 iOS Simulator 上的 Xcode App 构建。
7. `git diff --check`。

默认模拟器 UDID 来自脚本中的 `HOSTSHELL_IOS_SIMULATOR_ID`。在其他机器上先运行 `xcrun simctl list devices available`，然后覆盖为本机 UDID：

```sh
HOSTSHELL_IOS_SIMULATOR_ID="<本机模拟器 UDID>" ./scripts/check_regression.sh
```

当没有可用 iOS SDK/runtime，或只需要验证 Rust、CLI、Swift model 和 macOS 时，可以跳过 iOS 构建：

```sh
HOSTSHELL_SKIP_IOS_BUILD=1 ./scripts/check_regression.sh
```

这是部分回归，不代表三路全通过。回归脚本使用临时 HOME 执行 CLI fixture 导入，不会连接 SSH 主机或改动用户配置。完整回归会重建被忽略的 XCFramework 和 app/derived data；完成后检查 `git status`，确认没有意外的源码或锁文件改动。

## 7. 提交前检查

```sh
git status --short --branch
git diff --check
git diff
```

确认变更只包含预期源码、文档和锁文件。不要提交 `target/`、SwiftPM `.build/` 或本地生成的 `apps/ios/Frameworks/HostShellCore.xcframework`。

## 8. 主要目录

| 路径 | 内容 |
|---|---|
| `crates/hostshell-core` | Rust SSH 核心库和 Swift FFI |
| `crates/hostshell-cli` | 终端 CLI |
| `apps/macos` | SwiftUI macOS 客户端 |
| `apps/ios` | SwiftUI iOS 客户端和 Xcode 工程 |
| `scripts/build_cli.sh` | CLI release 构建 |
| `scripts/build_macos.sh` | Rust core、macOS 客户端和 `.app` 打包 |
| `scripts/build_ios.sh` | iOS Rust device/simulator 库和 XCFramework |
| `scripts/check_regression.sh` | 三路本地回归流程 |
| `REGRESSION.md` | 回归覆盖范围和手动发布检查说明 |
