import SwiftUI
import AppKit
import SwiftTerm

// ── SwiftTerm bridge ─────────────────────────────────────────────────────────

/// Wraps SwiftTerm's AppKit TerminalView for SwiftUI and wires it to the SSH session.
struct SwiftTermRepresentable: NSViewRepresentable {
    @ObservedObject var sessionVM: SessionViewModel

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.sessionVM = sessionVM
        // Drain raw SSH output into the terminal emulator
        if let data = sessionVM.takePendingOutput() {
            tv.feed(byteArray: Array(data)[...])
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionVM: sessionVM)
    }

    final class Coordinator: TerminalViewDelegate {
        var sessionVM: SessionViewModel

        init(sessionVM: SessionViewModel) {
            self.sessionVM = sessionVM
        }

        /// Keystrokes from the emulated terminal → SSH channel.
        /// AppKit invokes this on the main thread; assumeIsolated is safe here.
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                sessionVM.sendBytes(Array(data))
            }
        }

        /// Terminal layout changes (window resize, font change) → SSH window-change.
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                sessionVM.resize(cols: UInt32(newCols), rows: UInt32(newRows))
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            // Header bar already shows host identity; ignore remote titles for now.
        }

        func setTerminalIconTitle(source: SwiftTerm.TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }

        func bell(source: SwiftTerm.TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

// ── Session terminal screen ──────────────────────────────────────────────────

public struct TerminalView: View {
    @ObservedObject var sessionVM: SessionViewModel
    public let onClose: () -> Void

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

            // Real terminal emulation: xterm sequences, 256 color, vim/tmux ready
            SwiftTermRepresentable(sessionVM: sessionVM)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
