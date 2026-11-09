import SwiftUI

public struct SshConfigImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appVM: AppViewModel

    @State private var configText: String = ""
    @State private var previewResponse: SshConfigImportResponse? = nil
    @State private var errorMessage: String? = nil
    @State private var showingFilePicker = false
    @State private var parsedText = ""

    private func conflicts(_ host: Host) -> Bool {
        appVM.hosts.contains { $0.name == host.name && $0.id != host.id }
            || previewResponse?.hosts.first(where: { $0.name == host.name })?.id != host.id
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导入 ~/.ssh/config 配置")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("从配置文件读取或粘贴 OpenSSH config 内容：")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    showingFilePicker = true
                } label: {
                    Label("选择 ~/.ssh/config 或 joyy 文件…", systemImage: "doc.badge.arrow.up")
                }
                .controlSize(.small)

                TextEditor(text: $configText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 140)
                    .border(Color.secondary.opacity(0.2))

                HStack {
                    Button("从剪贴板读取") {
                        if let str = NSPasteboard.general.string(forType: .string) {
                            configText = str
                        }
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("解析配置") {
                        parse()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                }

                if let resp = previewResponse {
                    Divider()

                    Text("解析预览：\(resp.hosts.count) 台主机，\(resp.jumpHosts?.count ?? 0) 个跳板机资产，\(resp.warnings.count) 条提示")
                        .font(.headline)

                    if !resp.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(resp.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    List(resp.hosts) { h in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.name).fontWeight(.medium)
                                Text(conflicts(h) ? "名称重复，将跳过" : "新主机")
                                    .font(.caption).foregroundColor(conflicts(h) ? .orange : .secondary)
                                Text("\(h.username)@\(h.hostname):\(h.port)").font(.caption).foregroundColor(.secondary)
                                ForEach(h.port_forwards ?? []) { rule in
                                    Label(rule.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                            }
                            Spacer()
                            Text(h.proxy_mode.badgeName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
                    .frame(height: 160)
                }

                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                if previewResponse != nil && configText != parsedText {
                    Text("配置已修改，请重新解析。").font(.caption).foregroundColor(.orange)
                }
                if appVM.assetLoadError != nil {
                    Text("资产列表不可用，请先恢复读取。 ").font(.caption).foregroundColor(.orange)
                }
                Button("导入新主机", action: importHosts)
                .buttonStyle(.borderedProminent)
                .disabled((previewResponse?.hosts.allSatisfy { conflicts($0) } ?? true) || configText != parsedText || appVM.assetLoadError != nil)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 560, height: 560)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    configText = try String(contentsOf: url, encoding: .utf8)
                    errorMessage = nil
                    parse()
                } catch {
                    previewResponse = nil
                    errorMessage = "读取文件失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func parse() {
        guard !configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewResponse = nil
            errorMessage = "配置内容为空。请选择 ~/.ssh/config 或 joyy 文件，或粘贴配置文本。"
            return
        }
        guard let response = HostShellBridge.shared.importSshConfig(text: configText) else {
            previewResponse = nil
            errorMessage = "配置解析失败。请检查配置内容及本地主机、跳板机资产是否可读取。"
            return
        }
        previewResponse = response
        parsedText = configText
        errorMessage = response.hosts.isEmpty
            ? "没有识别到可导入的 Host。请粘贴文件内容或使用上方选择文件，不能只输入文件路径。"
            : nil
    }

    private func importHosts() {
        guard let response = previewResponse, configText == parsedText, appVM.assetLoadError == nil else { return }
        let hosts = response.hosts.filter { !conflicts($0) }
        let jumpIDs = Set(hosts.flatMap { $0.jump_host_ids })
        for jump in response.jumpHosts ?? [] where jumpIDs.contains(jump.id) {
            guard appVM.saveJumpHost(jump) else {
                errorMessage = "保存跳板机失败，已保存的资产会保留；请检查本地文件后重试。"
                return
            }
        }
        for host in hosts {
            guard appVM.saveHost(host) else {
                errorMessage = "保存主机失败，已保存的资产会保留；请检查本地文件后重试。"
                return
            }
        }
        dismiss()
    }
}
