import SwiftUI
import AppKit
import Darwin
import SwiftTerm

/// Keeps HostShell completion control sequences out of the local terminal emulator.
/// The local PTY still receives all ordinary output and all native key input.
private final class HostShellLocalTerminalView: LocalProcessTerminalView {
    private var completionParser = ShellCompletionStreamParser()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let parsed = completionParser.consume(Array(slice))
        guard !parsed.visibleBytes.isEmpty else { return }
        feed(byteArray: parsed.visibleBytes[...])
    }
}

struct LocalTerminalHomeView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // Brand hero
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(HostShellPalette.cyan)
                            .frame(width: 58, height: 58)
                            .background(
                                LinearGradient(
                                    colors: [HostShellPalette.navy, HostShellPalette.deep],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("本地终端")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Text("LOCAL SHELL")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(HostShellPalette.cyan)
                        }
                        Spacer()
                    }

                    Text("直接在这台 Mac 上启动登录 Shell，无需 SSH 连接或网络。共享 HostShell 的等宽字体、配色与终端仿真设置。")
                        .font(.system(size: 13))
                        .foregroundStyle(HostShellPalette.n300)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        LocalTerminalWindowManager.shared.open()
                    } label: {
                        Label("打开本地终端", systemImage: "terminal")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(HostShellPalette.blue)
                }
                .padding(24)
                .background(
                    LinearGradient(
                        colors: [HostShellPalette.navy2, HostShellPalette.deep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(HostShellPalette.cyan.opacity(0.18), lineWidth: 1)
                )

                // Feature notes
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(HostShellPalette.blue)
                        Text("终端特性")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(HostShellPalette.canvas(colorScheme))

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        featureRow(icon: "textformat", color: HostShellPalette.cyan,
                                   title: "等宽字体与主题", detail: "字体、字号、深色/浅色主题与终端会话统一")
                        featureRow(icon: "rectangle.on.rectangle", color: HostShellPalette.blue,
                                   title: "完整终端仿真", detail: "xterm-256color，vim / tmux / htop 可用")
                        featureRow(icon: "app.badge", color: HostShellPalette.modeDirect,
                                   title: "独立标签窗口", detail: "在独立窗口运行，可与 SSH 会话并排使用")
                    }
                    .padding(16)
                }
                .background(HostShellPalette.panel(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

                Spacer(minLength: 20)
            }
            .padding(26)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(HostShellPalette.workspace(colorScheme))
    }

    private func featureRow(icon: String, color: SwiftUI.Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
    }
}

@MainActor
final class LocalTerminalWindowManager {
    static let shared = LocalTerminalWindowManager()
    private var windows: [UUID: LocalTerminalWindowController] = [:]

    func open() {
        let id = UUID()
        let controller = LocalTerminalWindowController { [weak self] in
            self?.windows.removeValue(forKey: id)
        }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class LocalTerminalWindowController: NSWindowController, NSWindowDelegate {
    private let onClosed: () -> Void

    init(onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "本地终端"
        window.tabbingIdentifier = "com.hostshell.local-terminal"
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 600, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: LocalTerminalWindowContent(onClose: { [weak self] in self?.close() })
        )
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        onClosed()
    }
}

private struct LocalTerminalWindowContent: View {
    let onClose: () -> Void
    @State private var processStatus = "正在启动登录 Shell…"

    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.fontFamilyKey) private var terminalFontFamily = TerminalFontFamily.system.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue
    @AppStorage(TerminalPreferences.cursorStyleKey) private var terminalCursorStyle = TerminalCursorStyle.block.rawValue
    @AppStorage(TerminalPreferences.emulationKey) private var terminalEmulation = TerminalEmulation.xterm256color.rawValue
    @AppStorage(TerminalPreferences.scrollbackLinesKey) private var terminalScrollbackLines = TerminalPreferences.defaultScrollbackLines

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle()
                    .fill(processStatus == "本地 Shell 正在运行" ? HostShellPalette.modeDirect : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("本地终端")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(processStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("新建终端") {
                    LocalTerminalWindowManager.shared.open()
                }
                .controlSize(.small)
                Button("关闭") { onClose() }
                    .controlSize(.small)
                    .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HostShellPalette.deep)

            Divider()

            LocalSwiftTermRepresentable(
                preferences: terminalPreferences,
                onProcessStatus: { processStatus = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            keepaliveSeconds: 0
        )
    }
}

private struct LocalSwiftTermRepresentable: NSViewRepresentable {
    let preferences: TerminalPreferences
    let onProcessStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessStatus: onProcessStatus)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = HostShellLocalTerminalView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 460),
            font: terminalFont,
            options: TerminalOptions(
                termName: preferences.emulation.rawValue,
                cursorStyle: swiftCursorStyle,
                scrollback: preferences.scrollbackLines
            )
        )
        terminal.processDelegate = context.coordinator
        applyAppearance(to: terminal)
        context.coordinator.processStatus = onProcessStatus
        terminal.startProcess(
            executable: LocalShell.executable,
            args: ["-l"],
            environment: Terminal.getEnvironmentVariables(termName: preferences.emulation.rawValue),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        DispatchQueue.main.async {
            guard terminal.process.running else { return }
            context.coordinator.processStatus("本地 Shell 正在运行")
        }
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        context.coordinator.processStatus = onProcessStatus
        applyAppearance(to: terminal)
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        terminal.terminate()
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

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var processStatus: (String) -> Void

        init(onProcessStatus: @escaping (String) -> Void) {
            processStatus = onProcessStatus
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            let status = exitCode.map { "本地 Shell 已退出（代码 \($0)）" } ?? "本地 Shell 已退出"
            DispatchQueue.main.async { self.processStatus(status) }
        }
    }
}

private enum LocalShell {
    static var executable: String {
        if let account = getpwuid(getuid()) {
            let shell = String(cString: account.pointee.pw_shell)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) {
                return shell
            }
        }
        return "/bin/zsh"
    }
}
