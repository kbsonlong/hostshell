import SwiftUI
import AppKit
import Darwin
import SwiftTerm

struct LocalTerminalHomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("本地终端")
                .font(.title2.weight(.semibold))
            Text("直接在这台 Mac 上启动登录 Shell。无需选择 SSH 主机或连接网络。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button {
                LocalTerminalWindowManager.shared.open()
            } label: {
                Label("打开本地终端", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
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
            HStack(spacing: 8) {
                Circle()
                    .fill(processStatus == "本地 Shell 正在运行" ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(processStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("新建终端") {
                    LocalTerminalWindowManager.shared.open()
                }
                .controlSize(.small)
                Button("关闭") { onClose() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

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
        let terminal = LocalProcessTerminalView(
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
