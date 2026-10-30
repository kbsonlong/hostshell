import SwiftUI

public struct HostEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appVM: AppViewModel

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String

    @State private var authChoice: Int // 0: password, 1: private key
    @State private var passwordText: String
    @State private var privateKeyText: String
    @State private var passphraseText: String

    @State private var proxyMode: ProxyMode
    @State private var selectedJumpHostIds: [String]

    @State private var cfAuthType: CloudflareAuthType
    @State private var cfClientId: String
    @State private var cfClientSecret: String
    @State private var cfCookie: String
    @State private var cfHostnameOverride: String

    @State private var tagInput: String
    @State private var errorMessage: String? = nil

    private let originalHost: Host?

    public init(appVM: AppViewModel, host: Host?) {
        self.appVM = appVM
        self.originalHost = host

        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: "\(host?.port ?? 22)")
        _username = State(initialValue: host?.username ?? "root")

        var authC = 0
        var pwd = ""
        var pk = ""
        var pass = ""
        if let auth = host?.auth {
            switch auth {
            case .password(let p):
                authC = 0
                pwd = p
            case .privateKey(let keyData, let passphrase):
                authC = 1
                pk = keyData
                pass = passphrase ?? ""
            case .agent:
                authC = 2
            }
        }
        _authChoice = State(initialValue: authC)
        _passwordText = State(initialValue: pwd)
        _privateKeyText = State(initialValue: pk)
        _passphraseText = State(initialValue: pass)

        _proxyMode = State(initialValue: host?.proxy_mode ?? .direct)
        _selectedJumpHostIds = State(initialValue: host?.jump_host_ids ?? [])

        let cf = host?.cloudflare_config
        _cfAuthType = State(initialValue: cf?.auth_type ?? .serviceToken)
        _cfClientId = State(initialValue: cf?.client_id ?? "")
        _cfClientSecret = State(initialValue: cf?.client_secret ?? "")
        _cfCookie = State(initialValue: cf?.cookie ?? "")
        _cfHostnameOverride = State(initialValue: cf?.hostname_override ?? "")

        _tagInput = State(initialValue: host?.tags.joined(separator: ", ") ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(originalHost == nil ? "新建主机配置" : "编辑主机配置")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Basic Information
                    GroupBox(label: Label("基础连接信息", systemImage: "server.rack")) {
                        VStack(spacing: 10) {
                            TextField("显示名称 (如: 生产K8s节点-01)", text: $name)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                TextField("主机地址 / IP (如: 192.168.1.100)", text: $hostname)
                                    .textFieldStyle(.roundedBorder)
                                TextField("端口", text: $port)
                                    .frame(width: 80)
                                    .textFieldStyle(.roundedBorder)
                            }

                            TextField("用户名 (如: root, ubuntu)", text: $username)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(6)
                    }

                    // Authentication Method
                    GroupBox(label: Label("目标主机认证凭证", systemImage: "key.fill")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("凭证类型", selection: $authChoice) {
                                Text("密码认证").tag(0)
                                Text("SSH 私钥").tag(1)
                                Text("SSH Agent").tag(2)
                            }
                            .pickerStyle(.segmented)

                            if authChoice == 0 {
                                SecureField("登录密码", text: $passwordText)
                                    .textFieldStyle(.roundedBorder)
                            } else if authChoice == 1 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("OpenSSH 私钥内容 (Ed25519 / RSA):")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextEditor(text: $privateKeyText)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(height: 90)
                                        .border(Color.secondary.opacity(0.2))

                                    HStack {
                                        Button("从私钥文件读取...") {
                                            openPrivateKeyFile()
                                        }
                                        .controlSize(.small)

                                        Spacer()

                                        SecureField("密钥密码 (Passphrase, 可选)", text: $passphraseText)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 220)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }

                    // Proxy Mode
                    GroupBox(label: Label("代理与网络通道 (三选一)", systemImage: "network")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("网络链路模式", selection: $proxyMode) {
                                ForEach(ProxyMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.radioGroup)

                            if proxyMode == .proxyJump {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("选择跳板机 (RFC 4254 direct-tcpip 隧道):")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    if appVM.jumpHosts.isEmpty {
                                        Text("暂无可用跳板机资产。请先在左侧「跳板机资产库」中添加。")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    } else {
                                        ForEach(appVM.jumpHosts) { jh in
                                            Toggle(isOn: Binding(
                                                get: { selectedJumpHostIds.contains(jh.id) },
                                                set: { isChecked in
                                                    if isChecked {
                                                        if !selectedJumpHostIds.contains(jh.id) {
                                                            selectedJumpHostIds.append(jh.id)
                                                        }
                                                    } else {
                                                        selectedJumpHostIds.removeAll(where: { $0 == jh.id })
                                                    }
                                                }
                                            )) {
                                                HStack {
                                                    Text(jh.name)
                                                        .fontWeight(.medium)
                                                    Text("(\(jh.username)@\(jh.hostname):\(jh.port))")
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.leading, 8)
                            } else if proxyMode == .cloudflareAccess {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Cloudflare Access 零信任隧道配置 (WSS 原生传输):")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    Picker("鉴权模式", selection: $cfAuthType) {
                                        ForEach(CloudflareAuthType.allCases) { auth in
                                            Text(auth.displayName).tag(auth)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    if cfAuthType == .serviceToken {
                                        TextField("CF-Access-Client-Id", text: $cfClientId)
                                            .textFieldStyle(.roundedBorder)
                                        SecureField("CF-Access-Client-Secret", text: $cfClientSecret)
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        TextField("CF_Authorization Cookie (或 Token)", text: $cfCookie)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    TextField("自定义接入 Hostname (留空则默认使用目标地址)", text: $cfHostnameOverride)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(6)
                    }

                    // Tags
                    GroupBox(label: Label("标签分类 (逗号分隔)", systemImage: "tag")) {
                        TextField("如: 生产, k8s, 香港机房", text: $tagInput)
                            .textFieldStyle(.roundedBorder)
                            .padding(6)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("保存配置") {
                    validateAndSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 540, height: 620)
    }

    private func openPrivateKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    privateKeyText = content
                }
            }
        }
    }

    private func validateAndSave() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请输入主机显示名称"
            return
        }
        guard !hostname.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请输入主机地址"
            return
        }
        guard let p = UInt16(port), p > 0 else {
            errorMessage = "请输入合法的端口号 (1-65535)"
            return
        }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请输入用户名"
            return
        }

        if proxyMode == .proxyJump && selectedJumpHostIds.isEmpty {
            errorMessage = "ProxyJump 跳板机模式必须至少勾选一个跳板机"
            return
        }

        if proxyMode == .cloudflareAccess {
            if cfAuthType == .serviceToken {
                if cfClientId.trimmingCharacters(in: .whitespaces).isEmpty ||
                    cfClientSecret.trimmingCharacters(in: .whitespaces).isEmpty {
                    errorMessage = "Cloudflare Service Token 必须填写 Client ID 与 Client Secret"
                    return
                }
            } else if cfCookie.trimmingCharacters(in: .whitespaces).isEmpty {
                errorMessage = "Cloudflare Web SSO 模式必须填写 Cookie/Token"
                return
            }
        }

        let auth: AuthMethod
        switch authChoice {
        case 0:
            auth = .password(passwordText)
        case 1:
            auth = .privateKey(
                keyData: privateKeyText,
                passphrase: passphraseText.isEmpty ? nil : passphraseText
            )
        default:
            auth = .agent
        }

        let cfConfig: CloudflareConfig?
        if proxyMode == .cloudflareAccess {
            cfConfig = CloudflareConfig(
                auth_type: cfAuthType,
                client_id: cfClientId.isEmpty ? nil : cfClientId,
                client_secret: cfClientSecret.isEmpty ? nil : cfClientSecret,
                cookie: cfCookie.isEmpty ? nil : cfCookie,
                hostname_override: cfHostnameOverride.isEmpty ? nil : cfHostnameOverride
            )
        } else {
            cfConfig = nil
        }

        let tags = tagInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let newHost = Host(
            id: originalHost?.id ?? UUID().uuidString,
            name: name,
            hostname: hostname,
            port: p,
            username: username,
            auth: auth,
            proxy_mode: proxyMode,
            jump_host_ids: proxyMode == .proxyJump ? selectedJumpHostIds : [],
            cloudflare_config: cfConfig,
            tags: tags,
            last_connected_at: originalHost?.last_connected_at,
            created_at: originalHost?.created_at ?? UInt64(Date().timeIntervalSince1970),
            updated_at: UInt64(Date().timeIntervalSince1970)
        )

        appVM.saveHost(newHost)
        dismiss()
    }
}
