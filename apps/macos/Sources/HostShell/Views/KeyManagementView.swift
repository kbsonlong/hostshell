import SwiftUI
import AppKit

struct KeyManagementView: View {
    @ObservedObject var appVM: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
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

    private var isReferenced: (SSHKeyMetadata) -> Bool {
        { item in
            appVM.hosts.contains { $0.auth == .keyRef(id: item.id) }
                || appVM.jumpHosts.contains { $0.auth == .keyRef(id: item.id) }
                || appVM.hosts.contains { $0.forward_agent_key_ids?.contains(item.id) == true }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Page header
                VStack(alignment: .leading, spacing: 4) {
                    Text("证书管理")
                        .font(.largeTitle.weight(.bold))
                    Text("导入 SSH 私钥后，可在多个主机和 Agent 转发中复用。私钥加密保存在系统 Keychain。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Key list group
                settingsGroup(title: "已导入的私钥", icon: "key.fill", systemImageColor: HostShellPalette.cyan) {
                    if appVM.keys.isEmpty {
                        emptyKeys
                    } else {
                        VStack(spacing: 0) {
                            ForEach(appVM.keys) { item in
                                keyRow(item)
                                if item.id != appVM.keys.last?.id {
                                    Divider().padding(.leading, 50)
                                }
                            }
                        }
                    }
                }

                // Import group
                settingsGroup(title: "导入私钥", icon: "square.and.arrow.down", systemImageColor: HostShellPalette.blue) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text("证书名称")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 78, alignment: .leading)
                            TextField("例如：生产环境 ed25519", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("OpenSSH 私钥内容")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = true
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = false
                                    if panel.runModal() == .OK, let url = panel.url {
                                        key = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                                    }
                                } label: {
                                    Label("从文件读取", systemImage: "doc.badge.arrow.up")
                                }
                                .controlSize(.small)
                            }
                            TextEditor(text: $key)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 96)
                                .padding(6)
                                .background(Color(NSColor.textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                )
                        }

                        HStack(spacing: 10) {
                            Text("私钥密码")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 78, alignment: .leading)
                            SecureField("Passphrase（可选）", text: $passphrase)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                error = appVM.addKey(name: name, key: key, passphrase: passphrase)
                                if error == nil { name = ""; key = ""; passphrase = "" }
                            } label: {
                                Label("保存私钥", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HostShellPalette.blue)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || key.isEmpty)
                        }

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(HostShellPalette.workspace(colorScheme))
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

    // MARK: - Key row

    private func keyRow(_ item: SSHKeyMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 15))
                .foregroundStyle(HostShellPalette.blue)
                .frame(width: 34, height: 34)
                .background(HostShellPalette.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                    statusBadge(
                        isReferenced(item) ? "已引用" : "未引用",
                        color: isReferenced(item) ? HostShellPalette.modeDirect : .secondary
                    )
                }
                Text("\(item.algorithm) · \(item.fingerprint)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Text(usageText(item))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(role: .destructive) { pendingDelete = item } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Empty keys

    private var emptyKeys: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("尚未导入任何私钥")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("在下方粘贴 OpenSSH 私钥或从文件读取，即可在主机间复用。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Reusable group / badge

    private func settingsGroup<Content: View>(
        title: String,
        icon: String,
        systemImageColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(systemImageColor)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(HostShellPalette.canvas(colorScheme))

            Divider()

            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(14)
        }
        .background(HostShellPalette.panel(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
