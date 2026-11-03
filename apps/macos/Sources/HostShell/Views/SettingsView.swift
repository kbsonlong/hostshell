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

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { terminalFontSize },
            set: { terminalFontSize = min(max($0.rounded(), 10), 24) }
        )
    }

    private var scrollbackBinding: Binding<Int> {
        Binding(
            get: { terminalScrollbackLines },
            set: { terminalScrollbackLines = min(max($0, 100), 10_000) }
        )
    }

    private var keepaliveBinding: Binding<Int> {
        Binding(
            get: { terminalKeepaliveSeconds },
            set: { terminalKeepaliveSeconds = $0 == 0 ? 0 : min(max($0, 5), 120) }
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置与诊断")
                        .font(.largeTitle.weight(.bold))
                    Text("调整终端显示、连接行为，并查看本机诊断信息。设置会自动保存在此 Mac。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    appearanceSection
                    sessionSection
                    securitySection
                    featuresSection
                    logSection
                    aboutSection
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var appearanceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("字体大小")
                    Spacer()
                    TextField("14", value: fontSizeBinding, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("pt").foregroundStyle(.secondary)
                }
                Slider(value: fontSizeBinding, in: 10...24, step: 1)
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
            .padding(.vertical, 6)
        } label: {
            Label("终端外观", systemImage: "textformat")
                .font(.headline)
        }
    }

    private var sessionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("终端仿真", selection: $terminalEmulation) {
                    ForEach(TerminalEmulation.allCases) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                numericRow(
                    title: "滚动缓冲区",
                    subtitle: "100–10,000 行",
                    value: scrollbackBinding,
                    range: 100...10_000,
                    step: 100,
                    unit: "行"
                )
                numericRow(
                    title: "SSH 心跳",
                    subtitle: "0 关闭；5–120 秒",
                    value: keepaliveBinding,
                    range: 0...120,
                    step: 5,
                    unit: "秒",
                    zeroLabel: "关闭"
                )
                Text("终端仿真和 SSH 心跳在下次连接时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } label: {
            Label("会话参数", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private func numericRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String,
        zeroLabel: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 92)
            Text(value.wrappedValue == 0 ? (zeroLabel ?? unit) : unit)
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .leading)
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(title)
        }
    }

    private var securitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("私钥与 Token 仅保存在本机安全存储中。")
                    .font(.callout)
                settingStatus("首次连接主机校验", value: "由核心引擎保护", color: .secondary)
            }
            .padding(.vertical, 6)
        } label: {
            Label("安全与 Host Key", systemImage: "shield.lefthalf.filled")
                .font(.headline)
        }
    }

    private var featuresSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                settingStatus("OpenSSH ProxyJump", value: "支持 direct-tcpip", color: .green)
                settingStatus("Cloudflare Access", value: "支持原生 WSS", color: .green)
                settingStatus("远程 DNS 解析保护", value: "已开启", color: .green)
            }
            .padding(.vertical, 6)
        } label: {
            Label("连接能力", systemImage: "network.badge.shield.half.filled")
                .font(.headline)
        }
    }

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("记录连接阶段、SSH Agent 身份尝试和错误详情；不记录密码、私钥或终端输出。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    HostShellBridge.shared.openLogDirectory()
                } label: {
                    Label("在 Finder 中打开日志目录", systemImage: "folder")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } label: {
            Label("本地连接日志", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
        }
    }

    private var aboutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                settingStatus("版本", value: "v0.1.0 MVP", color: .secondary)
                settingStatus("底层引擎", value: "Rust · hostshell-core", color: .secondary)
                settingStatus("界面", value: "SwiftUI · macOS / iOS", color: .secondary)
            }
            .padding(.vertical, 6)
        } label: {
            Label("关于 HostShell", systemImage: "info.circle")
                .font(.headline)
        }
    }

    private func settingStatus(_ title: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
