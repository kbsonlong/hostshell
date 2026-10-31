import SwiftUI
import AppKit

public struct ConnectionStageView: View {
    @ObservedObject var sessionVM: SessionViewModel
    public let onCancel: () -> Void

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                if sessionVM.isConnecting {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(.bottom, 4)
                    Text("正在连接到 \(sessionVM.host.name)...")
                        .font(.title2)
                        .fontWeight(.bold)
                } else if sessionVM.failureInfo != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.red)
                    Text("连接失败")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                } else if sessionVM.isDisconnected {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("连接已断开")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                Text("链路模式: \(sessionVM.host.proxy_mode.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 10)

            Divider()

            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                ForEach(sessionVM.stages) { item in
                    HStack(spacing: 12) {
                        if item.isFailed {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 16))
                        } else if item.isSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 16))
                        } else if item.isCurrent {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }

                        Text(item.description)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(item.isFailed ? .red : (item.isCurrent ? .primary : .secondary))
                            .textSelection(.enabled)

                        Spacer()
                    }
                }
              }
              .padding(.horizontal, 24)

            // Failure Diagnostics Callout (PRD FR-32)
            if let failure = sessionVM.failureInfo {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("故障定位: \(failure.stage)", systemImage: "stethoscope")
                            .font(.headline)
                            .foregroundColor(.red)
                        Spacer()
                        Text("分类: \(failure.category)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12))
                            .cornerRadius(4)
                    }

                    Text("错误详情: \(failure.message)")
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)

                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text("排错建议: \(failure.suggestion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 20)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Action footer
            HStack {
                Button("取消") {
                    sessionVM.disconnect()
                    onCancel()
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics, forType: .string)
                } label: {
                    Label("复制连接详情", systemImage: "doc.on.doc")
                }

                Spacer()

                if sessionVM.failureInfo != nil || sessionVM.isDisconnected {
                    Button("重试连接") {
                        sessionVM.connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnostics: String {
        var lines = ["主机: \(sessionVM.host.name) (\(sessionVM.host.username)@\(sessionVM.host.hostname):\(sessionVM.host.port))",
                     "连接方式: \(sessionVM.host.proxy_mode.displayName)"]
        lines += sessionVM.stages.map(\.description)
        if let failure = sessionVM.failureInfo {
            lines += ["故障阶段: \(failure.stage)", "错误分类: \(failure.category)",
                      "错误详情: \(failure.message)", "排错建议: \(failure.suggestion)"]
        }
        if sessionVM.isDisconnected && !sessionVM.disconnectReason.isEmpty {
            lines.append("断开原因: \(sessionVM.disconnectReason)")
        }
        return lines.joined(separator: "\n")
    }
}
