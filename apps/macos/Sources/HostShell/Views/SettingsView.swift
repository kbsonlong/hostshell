import SwiftUI

public struct SettingsView: View {
    @ObservedObject var appVM: AppViewModel
    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置与诊断")
                    .font(.title2)
                    .fontWeight(.bold)

                GroupBox(label: Label("终端外观", systemImage: "textformat")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("字体大小")
                            Spacer()
                            Text("\(Int(terminalFontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $terminalFontSize, in: 10...24, step: 1)
                            .accessibilityLabel("终端字体大小")
                        Picker("配色主题", selection: $terminalTheme) {
                            ForEach(TerminalTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("安全与 Host Key 管理", systemImage: "shield.lefthalf.filled")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("HostShell 遵循严格的 RFC 4254 与零信任协议标准，所有私钥与 Token 仅留存本地安全存储。")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("首次连接已知主机 (known_hosts):")
                            Spacer()
                            Text("已由核心引擎自动保护")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                }

                GroupBox(label: Label("零信任与跳板机特性支持", systemImage: "network.badge.shield.half.filled")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("OpenSSH ProxyJump 多跳中继:")
                            Spacer()
                            Text("支持 (direct-tcpip)").foregroundColor(.green)
                        }
                        HStack {
                            Text("Cloudflare Access (WSS 原生封装):")
                            Spacer()
                            Text("支持 (免外部二进制)").foregroundColor(.green)
                        }
                        HStack {
                            Text("远程 DNS 解析保护 (DNS Leaks Guard):")
                            Spacer()
                            Text("已开启").foregroundColor(.green)
                        }
                    }
                    .padding(6)
                }

                GroupBox(label: Label("本地连接日志", systemImage: "doc.text.magnifyingglass")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("记录连接阶段、SSH Agent 身份尝试和错误详情；不会记录密码、私钥或终端输出。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("在 Finder 中打开日志目录") {
                            HostShellBridge.shared.openLogDirectory()
                        }
                    }
                    .padding(6)
                }

                GroupBox(label: Label("关于 HostShell", systemImage: "info.circle")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("版本:")
                            Spacer()
                            Text("v0.1.0 MVP")
                        }
                        HStack {
                            Text("底层引擎:")
                            Spacer()
                            Text("Rust 跨平台核心 (hostshell-core)")
                        }
                        HStack {
                            Text("前端架构:")
                            Spacer()
                            Text("原生 SwiftUI (macOS / iOS 多架构准备)")
                        }
                    }
                    .padding(6)
                }

                Spacer()
            }
            .padding(24)
        }
    }
}
