import SwiftUI
import AppKit

public struct MainView: View {
    @StateObject private var appVM = AppViewModel()

    public var body: some View {
        NavigationSplitView {
            List(NavigationCategory.allCases, selection: $appVM.selectedCategory) { cat in
                NavigationLink(value: cat) {
                    Label(cat.rawValue, systemImage: cat.icon)
                }
            }
            .navigationTitle("HostShell")
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 200)
        } detail: {
            switch appVM.selectedCategory {
            case .hosts:
                HostListView(appVM: appVM)
            case .localTerminal:
                LocalTerminalHomeView()
            case .jumpHosts:
                JumpHostListView(appVM: appVM)
            case .keys:
                KeyManagementView(appVM: appVM)
            case .settings:
                SettingsView(appVM: appVM)
            }
        }
        .safeAreaInset(edge: .top) {
            if let error = appVM.assetLoadError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("重试读取") { appVM.loadData() }
                }
                .padding(8)
                .background(.orange.opacity(0.15))
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}

@MainActor
final class SessionWindowManager {
    static let shared = SessionWindowManager()
    private var windows: [UUID: SessionWindowController] = [:]

    func open(host: Host) {
        let currentWindow = NSApp.keyWindow.flatMap { keyWindow in
            windows.values.first { $0.window === keyWindow }?.window
        } ?? windows.values.first?.window
        let id = UUID()
        let controller = SessionWindowController(host: host) { [weak self] in
            self?.windows.removeValue(forKey: id)
        }
        windows[id] = controller
        controller.showWindow(nil)
        if let window = controller.window {
            if let currentWindow, currentWindow.tabGroup == nil || currentWindow.tabGroup !== window.tabGroup {
                currentWindow.addTabbedWindow(window, ordered: .above)
            }
            window.makeKeyAndOrderFront(nil)
        }
        controller.start()
    }
}

@MainActor
private final class SessionWindowController: NSWindowController, NSWindowDelegate {
    private let session: SessionViewModel
    private let onClosed: () -> Void

    init(host: Host, onClosed: @escaping () -> Void) {
        session = SessionViewModel(host: host)
        self.onClosed = onClosed
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = host.name
        window.tabbingIdentifier = "com.hostshell.terminal"
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 600, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SessionWindowContent(sessionVM: session) { [weak self] in
            self?.close()
        })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() { session.connect() }

    func windowWillClose(_ notification: Notification) {
        session.disconnect()
        onClosed()
    }
}

private struct SessionWindowContent: View {
    @ObservedObject var sessionVM: SessionViewModel
    let onClose: () -> Void
    @State private var hasConnected = false

    var body: some View {
        Group {
            if hasConnected || sessionVM.isConnected {
                TerminalView(sessionVM: sessionVM, onClose: onClose)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConnectionStageView(sessionVM: sessionVM, onCancel: onClose)
            }
        }
        .onChange(of: sessionVM.isConnected) { isConnected in
            if isConnected { hasConnected = true }
        }
        .onAppear {
            if sessionVM.isConnected { hasConnected = true }
        }
        .animation(.default, value: hasConnected)
    }
}
