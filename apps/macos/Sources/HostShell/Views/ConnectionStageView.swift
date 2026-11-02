import SwiftUI
import AppKit

public struct ConnectionStageView: View {
    @ObservedObject var sessionVM: SessionViewModel
    public let onCancel: () -> Void
    @State private var didCopyDiagnostics = false

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

                Button(action: copyDiagnostics) {
                    Label(
                        didCopyDiagnostics ? "已复制连接详情" : "复制连接详情",
                        systemImage: didCopyDiagnostics ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .tint(didCopyDiagnostics ? .green : .accentColor)
                .accessibilityHint("复制主机、连接阶段、错误原因和排错建议")

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
        .sheet(item: $sessionVM.authPromptInfo) { prompt in
            AuthInputSheet(sessionVM: sessionVM, prompt: prompt)
                .interactiveDismissDisabled()
        }
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        didCopyDiagnostics = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            didCopyDiagnostics = false
        }
    }

    private var diagnostics: String {
        var sections = [
            "HostShell 连接诊断",
            "==================",
            "\n【连接目标】",
            "主机：\(sessionVM.host.name)",
            "地址：\(sessionVM.host.username)@\(sessionVM.host.hostname):\(sessionVM.host.port)",
            "连接方式：\(sessionVM.host.proxy_mode.displayName)"
        ]

        if !sessionVM.stages.isEmpty {
            let stageLines = sessionVM.stages.enumerated().map { index, stage in
                "\(index + 1). \(stage.description)"
            }
            sections.append("\n【连接过程】\n" + stageLines.joined(separator: "\n"))
        }

        if let failure = sessionVM.failureInfo {
            sections.append(
                "\n【故障定位】\n故障阶段：\(failure.stage)\n错误分类：\(failure.category)"
            )
            sections.append("\n【错误详情】\n\(failure.message)")
            sections.append("\n【排错建议】\n\(failure.suggestion)")
        }
        if sessionVM.isDisconnected && !sessionVM.disconnectReason.isEmpty {
            sections.append("\n【断开原因】\n\(sessionVM.disconnectReason)")
        }
        return sections.joined(separator: "\n") + "\n"
    }
}

private struct AuthInputSheet: View {
    @ObservedObject var sessionVM: SessionViewModel
    let prompt: AuthPromptInfo
    @State private var response = ""
    @FocusState private var responseFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SSH authentication challenge")
                .font(.headline)
            if !prompt.name.isEmpty {
                Text(prompt.name)
                    .font(.subheadline)
            }
            if !prompt.instructions.isEmpty {
                Text(prompt.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Group {
                if prompt.echo {
                    TextField(prompt.prompt, text: $response)
                } else {
                    SecureField(prompt.prompt, text: $response)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($responseFocused)

            HStack {
                Button("取消") {
                    sessionVM.cancelAuthInput(for: prompt.id)
                }
                Spacer()
                Button("提交") {
                    sessionVM.submitAuthInput(response, for: prompt.id)
                    response = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear { responseFocused = true }
    }
}
