import SwiftUI
import AppKit

public struct TerminalView: View {
    @ObservedObject var sessionVM: SessionViewModel
    public let onClose: () -> Void

    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(sessionVM.isConnected ? Color.green : (sessionVM.isConnecting ? Color.yellow : Color.red))
                        .frame(width: 10, height: 10)
                    Text(sessionVM.host.name)
                        .font(.headline)
                    Text("(\(sessionVM.host.username)@\(sessionVM.host.hostname):\(sessionVM.host.port))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(sessionVM.host.proxy_mode.badgeName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                Spacer()

                if sessionVM.isDisconnected {
                    Button("重连") {
                        sessionVM.connect()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("断开并退出") {
                    sessionVM.disconnect()
                    onClose()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Terminal Screen Buffer
            ScrollViewReader { proxy in
                ScrollView {
                    Text(sessionVM.terminalOutput.isEmpty ? "连接中..." : sessionVM.terminalOutput)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminal_bottom")
                }
                .background(Color.black)
                .onChange(of: sessionVM.terminalOutput) { _ in
                    withAnimation {
                        proxy.scrollTo("terminal_bottom", anchor: .bottom)
                    }
                }
            }

            // Hidden or input capture field for keystrokes
            HStack(spacing: 8) {
                Text(">")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)

                TextField("在此键入命令并回车...", text: $inputText)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !inputText.isEmpty {
                            sessionVM.sendInput(inputText + "\n")
                            inputText = ""
                        }
                    }

                if !inputText.isEmpty {
                    Button("发送") {
                        sessionVM.sendInput(inputText + "\n")
                        inputText = ""
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Fixed Auxiliary Toolbar
            TerminalAccessoryBar { key in
                sessionVM.sendSpecialKey(key)
            }
        }
        .onAppear {
            isInputFocused = true
            sessionVM.resize(cols: 100, rows: 35)
        }
    }
}
