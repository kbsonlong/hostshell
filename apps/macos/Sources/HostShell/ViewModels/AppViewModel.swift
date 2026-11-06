import SwiftUI
import Combine

public enum NavigationCategory: String, CaseIterable, Identifiable {
    case hosts = "主机列表"
    case localTerminal = "本地终端"
    case jumpHosts = "跳板机资产库"
    case keys = "证书管理"
    case settings = "设置与诊断"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .localTerminal: return "terminal"
        case .jumpHosts: return "arrow.triangle.branch"
        case .keys: return "key.fill"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var selectedCategory: NavigationCategory = .hosts
    @Published public var hosts: [Host] = []
    @Published public var jumpHosts: [JumpHost] = []
    @Published public var keys: [SSHKeyMetadata] = []
    @Published public var searchQuery: String = ""
    @Published public var assetLoadError: String?

    // Sheet states
    @Published public var isShowingHostEditor: Bool = false
    @Published public var editingHost: Host? = nil

    @Published public var isShowingJumpHostEditor: Bool = false
    @Published public var editingJumpHost: JumpHost? = nil

    @Published public var isShowingImportSheet: Bool = false

    private let sessionWindows = SessionWindowManager.shared

    private let bridge = HostShellBridge.shared

    public init() {
        loadData()
    }

    public func loadData() {
        let loadedHosts = bridge.listHosts()
        let loadedJumps = bridge.listJumpHosts()
        if let loadedHosts { self.hosts = loadedHosts }
        if let loadedJumps { self.jumpHosts = loadedJumps }
        assetLoadError = loadedHosts == nil || loadedJumps == nil
            ? "无法读取主机或跳板机配置，请检查连接核心、本地文件和访问权限。已保留上次加载的列表。" : nil
        self.keys = bridge.listKeys()
    }

    public func addKey(name: String, key: String, passphrase: String) -> String? {
        let error = bridge.addKey(name: name, key: key, passphrase: passphrase)
        if error == nil { loadData() }
        return error
    }

    public func deleteKey(_ key: SSHKeyMetadata) -> String? {
        let result = bridge.deleteKey(key.id)
        if result == 0 { loadData(); return nil }
        return result == -2 ? "该证书仍被主机或 Agent 转发使用，请先解除引用。" : "删除失败，请检查 Keychain。"
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
        sessionWindows.open(host: host)
    }

    public func connect(to host: Host) {
        sessionWindows.open(host: host)
    }
}
