import SwiftUI

struct KnownHostsView: View {
    @State private var entries: [KnownHost] = []
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingDelete: KnownHost?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader

                // Trust list group
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HostShellPalette.modeDirect)
                        Text("已信任的主机 · \(entries.count)")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(HostShellPalette.canvas(colorScheme))

                    Divider()

                    if entries.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                hostRow(entry)
                                if entry.id != entries.last?.id {
                                    Divider().padding(.leading, 50)
                                }
                            }
                        }
                    }
                }
                .background(HostShellPalette.panel(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

                // Security note
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(HostShellPalette.blue)
                    Text("删除某台主机的指纹后，下次连接将重新信任服务器提供的密钥。删除前请先通过可信渠道核对新指纹，防范中间人攻击。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(HostShellPalette.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(HostShellPalette.workspace(colorScheme))
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

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("主机信任记录")
                    .font(.largeTitle.weight(.bold))
                Text("已保存的服务器与跳板机密钥指纹，用于检测连接时的密钥变更（Host Key 校验）。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: reload) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.regular)
        }
    }

    // MARK: - Host row

    private func hostRow(_ entry: KnownHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 15))
                .foregroundStyle(HostShellPalette.modeDirect)
                .frame(width: 34, height: 34)
                .background(HostShellPalette.modeDirect.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.hostname):\(entry.port)")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text(entry.key_type)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HostShellPalette.blue.opacity(0.12))
                        .foregroundStyle(HostShellPalette.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(entry.fingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(role: .destructive) { pendingDelete = entry } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("暂无主机信任记录")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("首次连接到 SSH 主机并确认指纹后，记录会显示在这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func reload() {
        guard let loaded = HostShellBridge.shared.listKnownHosts() else { error = "无法读取主机信任记录。"; return }
        entries = loaded.sorted { ($0.hostname, $0.port) < ($1.hostname, $1.port) }
    }
}
