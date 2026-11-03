import SwiftUI

public struct SettingsView: View {
    @ObservedObject var appVM: AppViewModel
    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.fontFamilyKey) private var terminalFontFamily = TerminalFontFamily.system.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue
    @AppStorage(TerminalPreferences.cursorStyleKey) private var terminalCursorStyle = TerminalCursorStyle.block.rawValue
    @AppStorage(TerminalPreferences.emulationKey) private var terminalEmulation = TerminalEmulation.xterm256color.rawValue
    @AppStorage(TerminalPreferences.scrollbackLinesKey) private var terminalScrollbackLines = TerminalPreferences.defaultScrollbackLines
    @AppStorage(TerminalPreferences.keepaliveSecondsKey) private var terminalKeepaliveSeconds = TerminalPreferences.defaultKeepaliveSeconds

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
                        Picker("等宽字体", selection: $terminalFontFamily) {
                            ForEach(TerminalFontFamily.allCases) { font in
                                Text(font.displayName).tag(font.rawValue)
                            }
                        }
                        Picker("配色主题", selection: $terminalTheme) {
                            ForEach(TerminalTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        Picker("光标样式", selection: $terminalCursorStyle) {
                            ForEach(TerminalCursorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox(label: Label("会话参数", systemImage: "slider.horizontal.3")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("终端仿真", selection: $terminalEmulation) {
                            ForEach(TerminalEmulation.allCases) { type in
                                Text(type.rawValue).tag(type.rawValue)
                            }
                        }
                        HStack {
                            Stepper(value: $terminalScrollbackLines, in: 100...10_000, step: 100) {
                                Text("滚动缓冲区")
                            }
                            Spacer()
                            Text("\(terminalScrollbackLines) 行").foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack {
                            Stepper(value: $terminalKeepaliveSeconds, in: 0...120, step: 5) {
                                Text("SSH 心跳")
                            }
                            Spacer()
                            Text(terminalKeepaliveSeconds == 0 ? "关闭" : "\(terminalKeepaliveSeconds) 秒")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text("心跳范围：关闭或 5–120 秒。滚动缓冲区范围：100–10,000 行。终端仿真和心跳在下次连接时生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
