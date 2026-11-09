import SwiftUI
import AppKit

struct KeyManagementView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var name = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var error: String?
    @State private var pendingDelete: SSHKeyMetadata?

    private func usageText(_ item: SSHKeyMetadata) -> String {
        let hosts = appVM.hosts.filter { $0.auth == .keyRef(id: item.id) }.count
        let jumps = appVM.jumpHosts.filter { $0.auth == .keyRef(id: item.id) }.count
        let forwards = appVM.hosts.filter { $0.forward_agent_key_ids?.contains(item.id) == true }.count
        var parts: [String] = []
        if hosts > 0 { parts.append("\(hosts) 台主机") }
        if jumps > 0 { parts.append("\(jumps) 个跳板机") }
        if forwards > 0 { parts.append("\(forwards) 处 Agent 转发") }
        return parts.isEmpty ? "未被引用" : "被 " + parts.joined(separator: " · ") + " 引用"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("证书管理").font(.title2.bold())
            Text("导入 SSH 私钥后，可在多个主机和 Agent 转发中使用。私钥保存在 Keychain。")
                .foregroundStyle(.secondary)
            List(appVM.keys) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name).font(.headline)
                        Text("\(item.algorithm) · \(item.fingerprint)").font(.caption).textSelection(.enabled)
                        Text(usageText(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除", role: .destructive) { pendingDelete = item }
                }.padding(.vertical, 4)
            }.frame(minHeight: 120)
            GroupBox("导入私钥") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("证书名称", text: $name)
                    TextEditor(text: $key).font(.system(.caption, design: .monospaced)).frame(height: 100)
                        .border(Color.secondary.opacity(0.25))
                    HStack {
                        Button("选择私钥文件") {
                            let panel = NSOpenPanel()
                            if panel.runModal() == .OK, let url = panel.url {
                                key = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                            }
                        }
                        SecureField("私钥密码（可选）", text: $passphrase)
                        Button("保存") {
                            error = appVM.addKey(name: name, key: key, passphrase: passphrase)
                            if error == nil { name = ""; key = ""; passphrase = "" }
                        }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || key.isEmpty)
                    }
                }.padding(6)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(20)
        .confirmationDialog("删除证书？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("删除 \(item.name)", role: .destructive) {
                error = appVM.deleteKey(item)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("\(usageText(item))。删除后私钥将从 Keychain 移除；被引用的证书需先解除引用。")
        }
    }
}
