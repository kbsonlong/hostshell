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
    @AppStorage(AIProviderSettings.enabledKey) private var aiEnabled = false
    @AppStorage(AIProviderSettings.baseURLKey) private var aiBaseURL = AIProviderSettings.defaultBaseURL
    @AppStorage(AIProviderSettings.modelKey) private var aiModel = ""
    @State private var aiAPIKey = ""
    @State private var availableAIModels: [String] = []
    @State private var refreshingAIModels = false
    @State private var aiSettingsMessage: String?

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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.largeTitle.weight(.bold))
                Text("按类别调整 HostShell。设置会自动保存在此 Mac。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            TabView {
                settingsScroll {
                    appearanceSection
                    sessionSection
                }
                .tabItem { Label("终端", systemImage: "textformat") }

                settingsScroll {
                    aiSection
                }
                .tabItem { Label("AI 助手", systemImage: "sparkles") }

                settingsScroll {
                    securitySection
                    featuresSection
                    logSection
                }
                .tabItem { Label("连接与诊断", systemImage: "network.badge.shield.half.filled") }

                settingsScroll {
                    aboutSection
                }
                .tabItem { Label("版本信息", systemImage: "info.circle") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        }
    }

    private var aiSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("启用 AI 助手", isOn: $aiEnabled)
                Text("只读分析终端问题，不会执行命令。终端内容不会自动发送；每次发送前都可检查和编辑。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("兼容 API 地址", text: $aiBaseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key（保存在 macOS Keychain）", text: $aiAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存 API Key", action: saveAIAPIKey)
                    if !aiAPIKey.isEmpty {
                        Text("Key 已载入或已填写")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("模型 ID", text: $aiModel)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if availableAIModels.isEmpty {
                        Text("可手动输入模型 ID，或刷新服务模型列表。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("可用模型", selection: $aiModel) {
                            ForEach(availableAIModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .frame(maxWidth: 280)
                    }
                    Spacer()
                    Button {
                        refreshAIModels()
                    } label: {
                        if refreshingAIModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新模型", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(refreshingAIModels)
                }
                if let aiSettingsMessage {
                    Text(aiSettingsMessage)
                        .font(.caption)
                        .foregroundStyle(aiSettingsMessage.hasPrefix("已") ? .green : .red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .task {
                if aiAPIKey.isEmpty {
                    aiAPIKey = AIProviderKeychain.loadAPIKey() ?? ""
                }
            }
        } label: {
            Label("AI 助手", systemImage: "sparkles")
                .font(.headline)
        }
    }

    private func saveAIAPIKey() {
        do {
            try AIProviderKeychain.saveAPIKey(aiAPIKey)
            aiSettingsMessage = "已安全保存 API Key。"
        } catch {
            aiSettingsMessage = error.localizedDescription
        }
    }

    private func refreshAIModels() {
        refreshingAIModels = true
        aiSettingsMessage = nil
        Task {
            do {
                let key = aiAPIKey.isEmpty ? (AIProviderKeychain.loadAPIKey() ?? "") : aiAPIKey
                availableAIModels = try await OpenAICompatibleProviderClient(baseURL: aiBaseURL, apiKey: key).listModels()
                if !availableAIModels.contains(aiModel), let first = availableAIModels.first {
                    aiModel = first
                }
                aiSettingsMessage = "已加载 \(availableAIModels.count) 个模型。"
            } catch {
                aiSettingsMessage = error.localizedDescription
            }
            refreshingAIModels = false
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
