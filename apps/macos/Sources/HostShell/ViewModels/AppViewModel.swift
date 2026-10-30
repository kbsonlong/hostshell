import SwiftUI
import Combine

public enum NavigationCategory: String, CaseIterable, Identifiable {
    case hosts = "主机列表"
    case jumpHosts = "跳板机资产库"
    case settings = "设置与诊断"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .jumpHosts: return "arrow.triangle.branch"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var selectedCategory: NavigationCategory = .hosts
    @Published public var hosts: [Host] = []
    @Published public var jumpHosts: [JumpHost] = []
    @Published public var searchQuery: String = ""

    // Sheet states
    @Published public var isShowingHostEditor: Bool = false
    @Published public var editingHost: Host? = nil

    @Published public var isShowingJumpHostEditor: Bool = false
    @Published public var editingJumpHost: JumpHost? = nil

    @Published public var isShowingImportSheet: Bool = false

    // Active session modal
    @Published public var activeSessionHost: Host? = nil

    private let bridge = HostShellBridge.shared

    public init() {
        loadData()
    }

    public func loadData() {
        self.hosts = bridge.listHosts()
        self.jumpHosts = bridge.listJumpHosts()
    }

    public var filteredHosts: [Host] {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return hosts
        }
        return hosts.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.hostname.localizedCaseInsensitiveContains(searchQuery) ||
            $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchQuery) })
        }
    }

    public func newHost() {
        editingHost = Host()
        isShowingHostEditor = true
    }

    public func editHost(_ host: Host) {
        editingHost = host
        isShowingHostEditor = true
    }

    public func saveHost(_ host: Host) {
        if bridge.saveHost(host) {
            loadData()
            isShowingHostEditor = false
            editingHost = nil
        }
    }

    public func deleteHost(_ host: Host) {
        if bridge.deleteHost(id: host.id) {
            loadData()
        }
    }

    public func newJumpHost() {
        editingJumpHost = JumpHost()
        isShowingJumpHostEditor = true
    }

    public func editJumpHost(_ jh: JumpHost) {
        editingJumpHost = jh
        isShowingJumpHostEditor = true
    }

    public func saveJumpHost(_ jh: JumpHost) {
        if bridge.saveJumpHost(jh) {
            loadData()
            isShowingJumpHostEditor = false
            editingJumpHost = nil
        }
    }

    public func deleteJumpHost(_ jh: JumpHost) {
        if bridge.deleteJumpHost(id: jh.id) {
            loadData()
        }
    }

    public func connect(to jumpHost: JumpHost) {
        let now = UInt64(Date().timeIntervalSince1970)
        let host = Host(
            id: jumpHost.id,
            name: jumpHost.name,
            hostname: jumpHost.hostname,
            port: jumpHost.port,
            username: jumpHost.username,
            auth: jumpHost.auth,
            proxy_mode: .direct,
            tags: ["jump-host"],
            created_at: now,
            updated_at: now
        )
        let session = SessionViewModel(host: host)
        activeJumpSessionVM = session
        session.connect()
    }

    @Published public var activeJumpSessionVM: SessionViewModel? = nil

    public func connect(to host: Host) {
        activeSessionHost = host
    }
}
