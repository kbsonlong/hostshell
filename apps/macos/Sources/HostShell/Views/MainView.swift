import SwiftUI
import AppKit

enum HostShellPalette {
    static let deep = Color(red: 0.027, green: 0.075, blue: 0.125)
    static let navy = Color(red: 0.051, green: 0.129, blue: 0.216)
    static let navy2 = Color(red: 0.078, green: 0.173, blue: 0.286)
    static let navyRaised = navy2
    static let cyan = Color(red: 0.373, green: 0.894, blue: 0.871)
    static let blue = Color(red: 0.286, green: 0.682, blue: 0.980)
    static let teal = Color(red: 0.231, green: 0.812, blue: 0.784)
    // Neutral scale (cool-tinted) from the design system
    static let n300 = Color(red: 0.796, green: 0.835, blue: 0.882)
    static let n400 = Color(red: 0.580, green: 0.639, blue: 0.714)
    // Semantic proxy-mode status colors (design-system.html)
    static let modeDirect = Color(red: 0.133, green: 0.773, blue: 0.369)    // #22c55e
    static let modeProxyJump = Color(red: 0.231, green: 0.510, blue: 0.965) // #3b82f6
    static let modeCloudflare = Color(red: 0.659, green: 0.333, blue: 0.969)// #a855f7
    static let modeProxyCommand = Color(red: 0.961, green: 0.620, blue: 0.043)// #f59e0b
    static let panel = Color(NSColor.controlBackgroundColor)
    static let canvas = Color(NSColor.windowBackgroundColor)
    static let workspace = Color(nsColor: NSColor(name: "HostShellWorkspace") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.075, green: 0.095, blue: 0.125, alpha: 1)
        }
        return NSColor(calibratedRed: 0.955, green: 0.969, blue: 0.984, alpha: 1)
    })

    static func proxyColor(_ mode: ProxyMode) -> Color {
        AppTheme.proxyColor(mode)
    }

    // Theme-aware surfaces. Call with the environment colorScheme so the
    // sidebar and the detail area stay in lockstep.
    static func workspace(_ scheme: ColorScheme) -> Color { AppTheme.canvas(scheme) }
    static func canvas(_ scheme: ColorScheme) -> Color { AppTheme.chrome(scheme) }
    static func panel(_ scheme: ColorScheme) -> Color { AppTheme.panel(scheme) }
}

public struct MainView: View {
    @StateObject private var appVM = AppViewModel()
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(AppTheme.modeKey) private var themeModeRaw = AppThemeMode.system.rawValue

    private var themeMode: AppThemeMode {
        AppTheme.mode(rawValue: themeModeRaw)
    }

    private var scheme: ColorScheme {
        AppTheme.effectiveScheme(mode: themeMode, system: systemScheme)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .safeAreaInset(edge: .top) {
            if let error = appVM.assetLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button("重试读取") { appVM.loadData() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .tint(AppTheme.blue)
        // Inject the resolved scheme so every child view — sidebar and detail
        // alike — resolves colors from the same appearance.
        .environment(\.colorScheme, scheme)
        .animation(.easeInOut(duration: 0.2), value: scheme)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let s = scheme
        return VStack(spacing: 0) {
            // Brand header
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.cyan)
                        .frame(width: 34, height: 34)
                        .background(
                            LinearGradient(
                                colors: [AppTheme.navy, AppTheme.deep],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("HostShell")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppTheme.sidebarText(s))
                        Text("移动 SSH 运维终端")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.sidebarTextInactive(s))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 16)
            .background(AppTheme.sidebarHeaderBackground(s))

            Divider()
                .background(AppTheme.border(s))

            // Navigation sections
            List(selection: $appVM.selectedCategory) {
                Section {
                    navLink(.hosts, icon: "server.rack", title: "主机列表", scheme: s)
                    navLink(.jumpHosts, icon: "arrow.triangle.branch", title: "跳板机资产库", scheme: s)
                    navLink(.keys, icon: "key.fill", title: "证书管理", scheme: s)
                    navLink(.knownHosts, icon: "checkmark.shield", title: "主机信任记录", scheme: s)
                } header: {
                    Text("资产").foregroundStyle(AppTheme.sidebarSectionTitle(s))
                }
                Section {
                    navLink(.localTerminal, icon: "terminal", title: "本地终端", scheme: s)
                } header: {
                    Text("工具").foregroundStyle(AppTheme.sidebarSectionTitle(s))
                }
                Section {
                    navLink(.settings, icon: "gearshape", title: "设置与诊断", scheme: s)
                } header: {
                    Text("系统").foregroundStyle(AppTheme.sidebarSectionTitle(s))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(AppTheme.sidebarGradient(s))
            .foregroundStyle(AppTheme.sidebarText(s))
        }
        .background(AppTheme.sidebarGradient(s))
        .frame(minWidth: 220, idealWidth: 240)
    }

    @ViewBuilder
    private func navLink(
        _ category: NavigationCategory,
        icon: String,
        title: String,
        scheme: ColorScheme
    ) -> some View {
        let isActive = appVM.selectedCategory == category
        NavigationLink(value: category) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isActive ? AppTheme.sidebarActiveIcon(scheme) : AppTheme.sidebarIcon(scheme))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AppTheme.sidebarActiveIcon(scheme) : AppTheme.sidebarText(scheme))
                Spacer()
            }
            .padding(.vertical, 3)
        }
        .listRowBackground(
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(AppTheme.sidebarActiveBackground(scheme))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
        )
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch appVM.selectedCategory {
        case .hosts:
            HostListView(appVM: appVM)
        case .localTerminal:
            LocalTerminalHomeView()
        case .jumpHosts:
            JumpHostListView(appVM: appVM)
        case .keys:
            KeyManagementView(appVM: appVM)
        case .knownHosts:
            KnownHostsView()
        case .settings:
            SettingsView(appVM: appVM)
        }
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
