import SwiftUI
import AppKit
import SwiftTerm

private final class HostShellMacTerminalView: SwiftTerm.TerminalView {
    var onSendSelectionToAI: ((String) -> Void)? {
        didSet { menu = makeContextMenu() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(sendSelectionToAI(_:)) {
            return onSendSelectionToAI != nil && !(getSelection()?.isEmpty ?? true)
        }
        return super.validateUserInterfaceItem(item)
    }

    private func makeContextMenu() -> NSMenu {
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
    @State private var aiMessages: [AIChatMessage] = []
    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.fontFamilyKey) private var terminalFontFamily = TerminalFontFamily.system.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue
    @AppStorage(TerminalPreferences.cursorStyleKey) private var terminalCursorStyle = TerminalCursorStyle.block.rawValue
    @AppStorage(TerminalPreferences.emulationKey) private var terminalEmulation = TerminalEmulation.xterm256color.rawValue
    @AppStorage(TerminalPreferences.scrollbackLinesKey) private var terminalScrollbackLines = TerminalPreferences.defaultScrollbackLines
    @AppStorage(TerminalPreferences.keepaliveSecondsKey) private var terminalKeepaliveSeconds = TerminalPreferences.defaultKeepaliveSeconds
    public let onClose: () -> Void

    public var body: some View {
        HSplitView {
          VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(sessionVM.isConnected ? Color.green : (sessionVM.isConnecting ? Color.yellow : Color.red))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionVM.host.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("\(sessionVM.host.username)@\(sessionVM.host.hostname):\(sessionVM.host.port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.58))
                    }
                    Text(sessionVM.host.proxy_mode.badgeName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(HostShellPalette.proxyColor(sessionVM.host.proxy_mode).opacity(0.18))
                        .foregroundColor(HostShellPalette.proxyColor(sessionVM.host.proxy_mode))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
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

                Button("断开") {
                    sessionVM.disconnect()
                    onClose()
                }
                .controlSize(.small)
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HostShellPalette.deep)

            Divider()

            // Real terminal emulation: xterm sequences, 256 color, vim/tmux ready
            ZStack(alignment: .bottomLeading) {
                SwiftTermRepresentable(
                    sessionVM: sessionVM,
                    preferences: terminalPreferences,
                    onSelectedTextForAI: { text in
                        selectedTextForAI = text
                        showingAIAssistant = true
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                if let completion = sessionVM.completionEvent,
                   !completion.candidates.isEmpty {
                    ShellCompletionMenu(
                        candidates: completion.candidates,
                        onSelect: { sessionVM.acceptCompletion($0) },
                        onDismiss: { sessionVM.dismissCompletion() }
                    )
                    .padding(12)
                }
            }

            terminalAccessoryBar
          }
          if showingAIAssistant {
              VStack(spacing: 0) {
                  HStack {
                      Text("AI 助手").font(.headline)
                      Spacer()
                      Button("隐藏") { showingAIAssistant = false }
                          .controlSize(.small)
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  Divider()
                  AIAssistantView(
                      terminalOutput: sessionVM.recentTerminalOutputText,
                      selectedText: selectedTextForAI,
                      messages: $aiMessages,
                      onClose: { showingAIAssistant = false }
                  )
              }
              .frame(minWidth: 380, idealWidth: 440, minHeight: 500)
          }
        }
    }

    private var terminalAccessoryBar: some View {
        HStack(spacing: 6) {
            terminalKey("ESC", action: { sessionVM.sendSpecialKey("ESC") })
            terminalKey("TAB", action: { sessionVM.sendSpecialKey("TAB") })
            keyDivider
            terminalKey("Ctrl+C", destructive: true, action: { sessionVM.sendSpecialKey("CTRL_C") })
            terminalKey("Ctrl+D", destructive: true, action: { sessionVM.sendSpecialKey("CTRL_D") })
            terminalKey("Ctrl+Z", destructive: true, action: { sessionVM.sendSpecialKey("CTRL_Z") })
            keyDivider
            terminalKey("|", action: { sessionVM.sendInput("|") })
            terminalKey("~", action: { sessionVM.sendInput("~") })
            terminalKey("/", action: { sessionVM.sendInput("/") })
            terminalKey("-", action: { sessionVM.sendInput("-") })
            keyDivider
            terminalKey("↑", action: { sessionVM.sendSpecialKey("UP") })
            terminalKey("↓", action: { sessionVM.sendSpecialKey("DOWN") })
            terminalKey("←", action: { sessionVM.sendSpecialKey("LEFT") })
            terminalKey("→", action: { sessionVM.sendSpecialKey("RIGHT") })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(HostShellPalette.deep)
    }

    private var keyDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private func terminalKey(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: title.count == 1 ? 12 : 10, weight: .medium, design: .monospaced))
                .foregroundColor(destructive ? Color(red: 1, green: 0.47, blue: 0.47) : Color.white.opacity(0.84))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
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
