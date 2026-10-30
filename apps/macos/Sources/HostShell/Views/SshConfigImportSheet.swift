import SwiftUI

public struct SshConfigImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appVM: AppViewModel

    @State private var configText: String = ""
    @State private var previewResponse: SshConfigImportResponse? = nil

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
                Text("从剪贴板粘贴本地 ~/.ssh/config 片段：")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

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

                if let resp = previewResponse {
                    Divider()

                    Text("解析预览 (发现 \(resp.hosts.count) 个主机，\(resp.warnings.count) 条提示):")
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
                                Text("\(h.username)@\(h.hostname):\(h.port)").font(.caption).foregroundColor(.secondary)
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
                Button("导入全部主机") {
                    if let resp = previewResponse {
                        for h in resp.hosts {
                            appVM.saveHost(h)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewResponse?.hosts.isEmpty ?? true)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 560, height: 560)
    }

    private func parse() {
        previewResponse = HostShellBridge.shared.importSshConfig(text: configText)
    }
}
