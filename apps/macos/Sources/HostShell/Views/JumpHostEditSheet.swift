import SwiftUI

public struct JumpHostEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appVM: AppViewModel

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String

    @State private var authChoice: Int
    @State private var passwordText: String
    @State private var privateKeyText: String
    @State private var passphraseText: String
    @State private var selectedKeyId: String

    @State private var errorMessage: String? = nil

    private let originalJumpHost: JumpHost?

    public init(appVM: AppViewModel, jumpHost: JumpHost?) {
        self.appVM = appVM
        self.originalJumpHost = jumpHost

        _name = State(initialValue: jumpHost?.name ?? "")
        _hostname = State(initialValue: jumpHost?.hostname ?? "")
        _port = State(initialValue: "\(jumpHost?.port ?? 22)")
        _username = State(initialValue: jumpHost?.username ?? "root")

        var authC = 0
        var pwd = ""
        var pk = ""
        var pass = ""
        var keyId = ""
        if let auth = jumpHost?.auth {
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
            case .keyRef(let id):
                authC = 3; keyId = id
            }
        }
        _authChoice = State(initialValue: authC)
        _passwordText = State(initialValue: pwd)
        _privateKeyText = State(initialValue: pk)
        _passphraseText = State(initialValue: pass)
        _selectedKeyId = State(initialValue: keyId)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(originalJumpHost == nil ? "添加跳板机资产" : "编辑跳板机资产")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("跳板机连接信息", systemImage: "arrow.triangle.branch")) {
                    VStack(spacing: 10) {
                        TextField("跳板机名称 (如: 运维堡垒机-01)", text: $name)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            TextField("跳板机 IP / 域名", text: $hostname)
                                .textFieldStyle(.roundedBorder)
                            TextField("端口", text: $port)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }

                        TextField("跳板机登录用户名", text: $username)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("跳板机认证凭证", systemImage: "key.fill")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("凭据类型", selection: $authChoice) {
                            Text("密码认证").tag(0)
                            Text("SSH 私钥").tag(1)
                            Text("SSH Agent").tag(2)
                            Text("已保存证书").tag(3)
                        }
                        .pickerStyle(.segmented)

                        if authChoice == 0 {
                            SecureField("跳板机登录密码", text: $passwordText)
                                .textFieldStyle(.roundedBorder)
                        } else if authChoice == 3 {
                            Picker("证书", selection: $selectedKeyId) {
                                Text("选择证书").tag("")
                                ForEach(appVM.keys) { Text($0.name).tag($0.id) }
                            }
                        } else if authChoice == 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("OpenSSH 私钥内容:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextEditor(text: $privateKeyText)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(height: 80)
                                    .border(Color.secondary.opacity(0.2))

                                SecureField("密钥密码 (Passphrase, 可选)", text: $passphraseText)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(6)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("保存跳板机") {
                    validateAndSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 480, height: 490)
    }

    private func validateAndSave() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请输入跳板机名称"
            return
        }
        guard !hostname.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请输入跳板机地址"
            return
        }
        guard let p = UInt16(port), p > 0 else {
            errorMessage = "请输入合法端口号 (1-65535)"
            return
        }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请输入用户名"
            return
        }

        if authChoice == 3 && !appVM.keys.contains(where: { $0.id == selectedKeyId }) {
            errorMessage = "请选择有效证书"
            return
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
        case 3:
            auth = .keyRef(id: selectedKeyId)
        default:
            auth = .agent
        }

        let jh = JumpHost(
            id: originalJumpHost?.id ?? UUID().uuidString,
            name: name,
            hostname: hostname,
            port: p,
            username: username,
            auth: auth
        )

        appVM.saveJumpHost(jh)
        dismiss()
    }
}
