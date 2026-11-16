import SwiftUI
import AppKit

public struct ConnectionStageView: View {
    @ObservedObject var sessionVM: SessionViewModel
    @Environment(\.colorScheme) private var colorScheme
    public let onCancel: () -> Void
    @State private var didCopyDiagnostics = false

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Stage timeline
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    stageTimeline

                    if let failure = sessionVM.failureInfo {
                        failureCard(failure)
                            .padding(.top, 16)
                    }
                }
                .padding(24)
            }

            Divider()

            // Action footer
            footer
        }
        .background(Color(NSColor.underPageBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $sessionVM.authPromptInfo) { prompt in
            AuthInputSheet(sessionVM: sessionVM, prompt: prompt)
                .interactiveDismissDisabled()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                statusIcon
                    .frame(width: 52, height: 52)
                    .background(statusColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(statusColor)

                    HStack(spacing: 8) {
                        Image(systemName: proxySymbol)
                            .font(.system(size: 10))
                            .foregroundColor(HostShellPalette.proxyColor(sessionVM.host.proxy_mode))
                        Text(sessionVM.host.proxy_mode.displayName)
                            .font(.caption)
                            .foregroundColor(HostShellPalette.proxyColor(sessionVM.host.proxy_mode))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(HostShellPalette.proxyColor(sessionVM.host.proxy_mode).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(sessionVM.host.username)@\(sessionVM.host.hostname):\(sessionVM.host.port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
    }

    private var statusIcon: some View {
        Group {
            if sessionVM.isConnecting {
                ProgressView()
                    .scaleEffect(1.3)
                    .frame(width: 48, height: 48)
            } else if sessionVM.failureInfo != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.red)
                    .frame(width: 48, height: 48)
            } else if sessionVM.isDisconnected {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
                    .frame(width: 48, height: 48)
            }
        }
    }

    private var proxySymbol: String {
        switch sessionVM.host.proxy_mode {
        case .direct: "link"
        case .proxyJump: "arrow.triangle.branch"
        case .proxyCommand: "terminal"
        case .cloudflareAccess: "shield.checkerboard"
        }
    }

    private var statusTitle: String {
        if sessionVM.isConnecting { return "正在连接到 \(sessionVM.host.name)..." }
        if sessionVM.failureInfo != nil { return "连接失败" }
        if sessionVM.isDisconnected { return "连接已断开" }
        return ""
    }

    private var statusColor: Color {
        if sessionVM.isConnecting { return .primary }
        if sessionVM.failureInfo != nil { return .red }
        if sessionVM.isDisconnected { return .orange }
        return .primary
    }

    // MARK: - Stage Timeline

    private var stageTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sessionVM.stages.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    // Timeline indicator
                    ZStack {
                        if index < sessionVM.stages.count - 1 {
                            Rectangle()
                                .fill(
                                    item.isSuccess ? Color.green.opacity(0.3) :
                                    item.isFailed ? Color.red.opacity(0.3) :
                                    Color.secondary.opacity(0.15)
                                )
                                .frame(width: 2)
                                .offset(y: 14)
                        }

                        stageIcon(for: item)
                    }
                    .frame(width: 24, height: 24)

                    // Stage description
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(
                                item.isFailed ? .red :
                                item.isCurrent ? .primary :
                                .secondary
                            )
                            .textSelection(.enabled)
                    }

                    Spacer()
                }
                .padding(.bottom, index < sessionVM.stages.count - 1 ? 14 : 0)
            }
        }
        .padding(16)
        .background(HostShellPalette.panel(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder
    private func stageIcon(for item: StageItem) -> some View {
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
                .scaleEffect(0.65)
                .frame(width: 16, height: 16)
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Failure Card

    private func failureCard(_ failure: FailureInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "stethoscope")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                Text("故障定位: \(failure.stage)")
                    .font(.headline)
                    .foregroundColor(.red)
                Spacer()
                Text(failure.category)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(4)
            }

            Divider()
                .background(Color.red.opacity(0.15))

            // Error message
            VStack(alignment: .leading, spacing: 4) {
                Text("错误详情")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(failure.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Suggestion
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("排错建议")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(failure.suggestion)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(8)
        }
        .padding(16)
        .background(Color.red.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: {
                sessionVM.disconnect()
                onCancel()
            }) {
                Label("取消", systemImage: "xmark")
            }

            Button(action: copyDiagnostics) {
                Label(
                    didCopyDiagnostics ? "已复制" : "复制诊断",
                    systemImage: didCopyDiagnostics ? "checkmark.circle.fill" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .tint(didCopyDiagnostics ? .green : .accentColor)

            Spacer()

            if sessionVM.failureInfo != nil || sessionVM.isDisconnected {
                Button(action: { sessionVM.connect() }) {
                    Label("重试连接", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(HostShellPalette.canvas(colorScheme))
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
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundColor(.accentColor)
                Text("SSH 认证请求")
                    .font(.headline)
            }

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
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { responseFocused = true }
    }
}
