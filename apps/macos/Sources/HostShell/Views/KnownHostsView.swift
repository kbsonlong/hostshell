import SwiftUI

struct KnownHostsView: View {
    @State private var entries: [KnownHost] = []
    @State private var pendingDelete: KnownHost?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("主机信任记录").font(.title2.bold())
                Spacer()
                Button("刷新", action: reload)
            }
            Text("已保存的服务器和跳板机密钥指纹用于检测密钥变化。")
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("暂无主机信任记录").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(entry.hostname):\(entry.port)").font(.headline)
                            Text("\(entry.key_type) · \(entry.fingerprint)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("删除", role: .destructive) { pendingDelete = entry }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .onAppear(perform: reload)
        .confirmationDialog("删除主机信任记录？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { entry in
            Button("删除", role: .destructive) {
                let result = HostShellBridge.shared.deleteKnownHost(entry)
                pendingDelete = nil
                if result != 0 { error = result == 1 ? "记录已变化，请刷新后重试。" : "删除失败，请检查本地存储。" }
                reload()
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text("删除 \(entry.hostname):\(entry.port) 的指纹后，下次连接将自动信任服务器提供的密钥。请先通过可信渠道核对新指纹。")
        }
        .alert("主机信任记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reload() {
        guard let loaded = HostShellBridge.shared.listKnownHosts() else { error = "无法读取主机信任记录。"; return }
        entries = loaded.sorted { ($0.hostname, $0.port) < ($1.hostname, $1.port) }
    }
}
