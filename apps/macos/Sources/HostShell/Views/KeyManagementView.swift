import SwiftUI
import AppKit

struct KeyManagementView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var name = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var error: String?

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
                    }
                    Spacer()
                    Button("删除", role: .destructive) { error = appVM.deleteKey(item) }
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
        }.padding(20)
    }
}
