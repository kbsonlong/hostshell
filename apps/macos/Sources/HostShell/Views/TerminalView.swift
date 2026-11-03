import SwiftUI
import AppKit
import SwiftTerm

private final class HostShellMacTerminalView: SwiftTerm.TerminalView {
    var onSendSelectionToAI: ((String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = getSelection() != nil
        menu.addItem(copy)

        let askAI = NSMenuItem(title: "发送选中内容给 AI 助手", action: #selector(sendSelectionToAI(_:)), keyEquivalent: "")
        askAI.target = self
        askAI.isEnabled = onSendSelectionToAI != nil && !(getSelection()?.isEmpty ?? true)
        menu.addItem(askAI)
        return menu
    }

    @objc private func sendSelectionToAI(_ sender: Any?) {
        guard let selection = getSelection(), !selection.isEmpty else { return }
        onSendSelectionToAI?(selection)
    }
}

// ── SwiftTerm bridge ─────────────────────────────────────────────────────────

/// Wraps SwiftTerm's AppKit TerminalView for SwiftUI and wires it to the SSH session.
struct SwiftTermRepresentable: NSViewRepresentable {
    @ObservedObject var sessionVM: SessionViewModel
    let preferences: TerminalPreferences
    let onSelectedTextForAI: ((String) -> Void)?

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        // SwiftTerm derives its initial rows and columns from the frame.
        let options = SwiftTerm.TerminalOptions(
            termName: preferences.emulation.rawValue,
            cursorStyle: swiftCursorStyle,
            scrollback: preferences.scrollbackLines
        )
        let tv = HostShellMacTerminalView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 460),
            font: terminalFont,
            options: options
        )
        tv.onSendSelectionToAI = onSelectedTextForAI
        applyAppearance(to: tv)
        tv.terminalDelegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.sessionVM = sessionVM
        (tv as? HostShellMacTerminalView)?.onSendSelectionToAI = onSelectedTextForAI
        applyAppearance(to: tv)
        // Drain raw SSH output into the terminal emulator
        if let data = sessionVM.takePendingOutput() {
            tv.feed(byteArray: Array(data)[...])
        }
    }

    private func applyAppearance(to view: SwiftTerm.TerminalView) {
        if view.font != terminalFont {
            view.font = terminalFont
        }
        let terminal = view.getTerminal()
        terminal.setCursorStyle(swiftCursorStyle)
        if terminal.options.scrollback != preferences.scrollbackLines {
            terminal.changeHistorySize(preferences.scrollbackLines)
        }
        switch preferences.theme {
        case .dark:
            view.nativeBackgroundColor = .black
            view.nativeForegroundColor = .white
        case .light:
            view.nativeBackgroundColor = .white
            view.nativeForegroundColor = .black
        }
    }

    private var terminalFont: NSFont {
        let size = CGFloat(min(max(preferences.fontSize, 10), 24))
        if let name = preferences.fontFamily.postScriptName,
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var swiftCursorStyle: SwiftTerm.CursorStyle {
        switch preferences.cursorStyle {
        case .block: return .blinkBlock
        case .underline: return .steadyUnderline
        case .bar: return .steadyBar
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
            guard let cols = UInt32(exactly: newCols), let rows = UInt32(exactly: newRows),
                  cols > 0, rows > 0 else { return }
            MainActor.assumeIsolated {
                sessionVM.resize(cols: cols, rows: rows)
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
    @AppStorage(AIProviderSettings.enabledKey) private var aiEnabled = false
    @State private var showingAIAssistant = false
    @State private var selectedTextForAI: String?
    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.fontFamilyKey) private var terminalFontFamily = TerminalFontFamily.system.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue
    @AppStorage(TerminalPreferences.cursorStyleKey) private var terminalCursorStyle = TerminalCursorStyle.block.rawValue
    @AppStorage(TerminalPreferences.emulationKey) private var terminalEmulation = TerminalEmulation.xterm256color.rawValue
    @AppStorage(TerminalPreferences.scrollbackLinesKey) private var terminalScrollbackLines = TerminalPreferences.defaultScrollbackLines
    @AppStorage(TerminalPreferences.keepaliveSecondsKey) private var terminalKeepaliveSeconds = TerminalPreferences.defaultKeepaliveSeconds
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

                if aiEnabled {
                    Button {
                        selectedTextForAI = nil
                        showingAIAssistant = true
                    } label: {
                        Label("AI 助手", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .help("分析终端问题；不会执行命令")
                }

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
            SwiftTermRepresentable(
                sessionVM: sessionVM,
                preferences: terminalPreferences,
                onSelectedTextForAI: aiEnabled ? { text in
                    selectedTextForAI = text
                    showingAIAssistant = true
                } : nil
            )
                .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showingAIAssistant) {
            AIAssistantView(
                terminalOutput: sessionVM.recentTerminalOutputText,
                selectedText: selectedTextForAI
            )
                .frame(minWidth: 560, minHeight: 500)
        }
    }

    private var terminalPreferences: TerminalPreferences {
        TerminalPreferences(
            fontSize: terminalFontSize,
            fontFamily: TerminalFontFamily(rawValue: terminalFontFamily) ?? .system,
            theme: TerminalTheme(rawValue: terminalTheme) ?? .dark,
            cursorStyle: TerminalCursorStyle(rawValue: terminalCursorStyle) ?? .block,
            emulation: TerminalEmulation(rawValue: terminalEmulation) ?? .xterm256color,
            scrollbackLines: terminalScrollbackLines,
            keepaliveSeconds: terminalKeepaliveSeconds
        )
    }
}
