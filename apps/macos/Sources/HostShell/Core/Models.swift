import Foundation

public enum TerminalTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

public struct TerminalPreferences: Codable, Equatable, Sendable {
    public static let fontSizeKey = "terminal.fontSize"
    public static let themeKey = "terminal.theme"
    public static let defaultFontSize = 14.0

    public var fontSize: Double
    public var theme: TerminalTheme

    public init(fontSize: Double = Self.defaultFontSize, theme: TerminalTheme = .dark) {
        self.fontSize = min(max(fontSize, 10), 24)
        self.theme = theme
    }
}

public enum ProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct = "direct"
    case proxyJump = "proxy_jump"
    case cloudflareAccess = "cloudflare_access"
    case proxyCommand = "proxy_command"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .direct: return "直连 (Direct)"
        case .proxyJump: return "跳板机 (ProxyJump)"
        case .cloudflareAccess: return "零信任 (Cloudflare Access)"
        case .proxyCommand: return "代理命令 (ProxyCommand)"
        }
    }

    public var badgeName: String {
        switch self {
        case .direct: return "直连"
        case .proxyJump: return "ProxyJump"
        case .cloudflareAccess: return "Cloudflare"
        case .proxyCommand: return "ProxyCommand"
        }
    }
}

public enum CloudflareAuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case serviceToken = "service_token"
    case webSso = "web_sso"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .serviceToken: return "Service Token (免登录推荐)"
        case .webSso: return "Web SSO (企业 IdP 登录)"
        }
    }
}

public struct CloudflareConfig: Codable, Equatable, Sendable {
    public var auth_type: CloudflareAuthType
    public var client_id: String?
    public var client_secret: String?
    public var cookie: String?
    public var hostname_override: String?

    public init(
        auth_type: CloudflareAuthType = .serviceToken,
        client_id: String? = nil,
        client_secret: String? = nil,
        cookie: String? = nil,
        hostname_override: String? = nil
    ) {
        self.auth_type = auth_type
        self.client_id = client_id
        self.client_secret = client_secret
        self.cookie = cookie
        self.hostname_override = hostname_override
    }
}

public enum AuthMethod: Codable, Equatable, Sendable {
    case password(String)
    case privateKey(keyData: String, passphrase: String?)
    case agent
    case keyRef(id: String)

    enum CodingKeys: String, CodingKey {
        case password
        case private_key
        case key_ref
        case agent
    }

    private struct KeyRefPayload: Codable { let id: String }

    private struct PrivateKeyPayload: Codable {
        let key_data: String
        let passphrase: String?
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self),
           value == "agent" {
            self = .agent
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pwd = try? container.decode(String.self, forKey: .password) {
            self = .password(pwd)
        } else if let pk = try? container.decode(PrivateKeyPayload.self, forKey: .private_key) {
            self = .privateKey(keyData: pk.key_data, passphrase: pk.passphrase)
        } else if let ref = try? container.decode(KeyRefPayload.self, forKey: .key_ref) {
            self = .keyRef(id: ref.id)
        } else if (try? container.decodeNil(forKey: .agent)) == true {
            self = .agent
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown SSH auth method"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .password(let pwd):
            try container.encode(pwd, forKey: .password)
        case .privateKey(let keyData, let passphrase):
            try container.encode(PrivateKeyPayload(key_data: keyData, passphrase: passphrase), forKey: .private_key)
        case .keyRef(let id):
            try container.encode(KeyRefPayload(id: id), forKey: .key_ref)
        case .agent:
            try container.encodeNil(forKey: .agent)
        }
    }
}

public struct JumpHost: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var auth: AuthMethod

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        hostname: String = "",
        port: UInt16 = 22,
        username: String = "root",
        auth: AuthMethod = .password("")
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
    }
}

public struct ForwardEndpoint: Codable, Equatable, Sendable {
    public var endpoint_type: String
    public var address: String?
    public var port: UInt16?
    public var path: String?

    public var displayName: String {
        if endpoint_type == "streamlocal" { return path ?? "Unix socket" }
        return "\(address ?? "127.0.0.1"):\(port ?? 0)"
    }

    public var configValue: String { endpoint_type == "streamlocal" ? (path ?? "") : displayName }
}

public struct PortForwardRule: Codable, Equatable, Identifiable, Sendable {
    public var direction: String
    public var bind: ForwardEndpoint
    public var target: ForwardEndpoint?

    public var id: String { "\(direction):\(bind.displayName):\(target?.displayName ?? "")" }

    public var displayName: String {
        let title = direction == "dynamic" ? "SOCKS5" : (direction == "remote" ? "RemoteForward" : "LocalForward")
        guard let target else { return "\(title) · \(bind.displayName)" }
        return "\(title) · \(bind.displayName) → \(target.displayName)"
    }

    public static func parse(direction: String, bind: String, target: String) -> PortForwardRule? {
        guard ["local", "remote", "dynamic"].contains(direction),
              let bindEndpoint = parseEndpoint(bind, expandTilde: direction != "remote") else { return nil }
        if direction == "dynamic" {
            guard bindEndpoint.endpoint_type == "tcp" else { return nil }
            return PortForwardRule(direction: direction, bind: bindEndpoint, target: nil)
        }
        guard let targetEndpoint = parseEndpoint(target, expandTilde: direction == "remote") else { return nil }
        return PortForwardRule(direction: direction, bind: bindEndpoint, target: targetEndpoint)
    }

    private static func parseEndpoint(_ rawValue: String, expandTilde: Bool) -> ForwardEndpoint? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let isSocket = value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("./")
            || (!value.contains(":") && UInt16(value) == nil)
        if isSocket {
            let path = expandTilde ? (value as NSString).expandingTildeInPath : value
            return ForwardEndpoint(endpoint_type: "streamlocal", address: nil, port: nil, path: path)
        }

        let address: String
        let portText: String
        if value.hasPrefix("["), let close = value.firstIndex(of: "]"), value[value.index(after: close)...].hasPrefix(":") {
            address = String(value[value.index(after: value.startIndex)..<close])
            portText = String(value[value.index(after: close)...].dropFirst())
        } else if let colon = value.lastIndex(of: ":") {
            address = String(value[..<colon])
            portText = String(value[value.index(after: colon)...])
            if address.contains(":"), !value.hasPrefix("[") { return nil }
        } else {
            address = "127.0.0.1"
            portText = value
        }
        guard let port = UInt16(portText), port > 0 else { return nil }
        return ForwardEndpoint(
            endpoint_type: "tcp",
            address: address == "*" ? "0.0.0.0" : (address.isEmpty ? "127.0.0.1" : address),
            port: port,
            path: nil
        )
    }
}

public struct Host: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var auth: AuthMethod
    public var proxy_mode: ProxyMode
    public var forward_agent: Bool?
    public var forward_agent_host_ids: [String]?
    public var forward_agent_key_ids: [String]?
    public var jump_host_ids: [String]
    public var proxy_command: String?
    public var cloudflare_config: CloudflareConfig?
    public var port_forwards: [PortForwardRule]?
    public var tags: [String]
    public var last_connected_at: UInt64?
    public var created_at: UInt64
    public var updated_at: UInt64

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        hostname: String = "",
        port: UInt16 = 22,
        username: String = "root",
        auth: AuthMethod = .password(""),
        proxy_mode: ProxyMode = .direct,
        forward_agent: Bool = false,
        forward_agent_host_ids: [String] = [],
        forward_agent_key_ids: [String] = [],
        jump_host_ids: [String] = [],
        proxy_command: String? = nil,
        cloudflare_config: CloudflareConfig? = nil,
        port_forwards: [PortForwardRule]? = [],
        tags: [String] = [],
        last_connected_at: UInt64? = nil,
        created_at: UInt64 = UInt64(Date().timeIntervalSince1970),
        updated_at: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.proxy_mode = proxy_mode
        self.forward_agent = forward_agent
        self.forward_agent_host_ids = forward_agent_host_ids
        self.forward_agent_key_ids = forward_agent_key_ids
        self.jump_host_ids = jump_host_ids
        self.proxy_command = proxy_command
        self.cloudflare_config = cloudflare_config
        self.port_forwards = port_forwards
        self.tags = tags
        self.last_connected_at = last_connected_at
        self.created_at = created_at
        self.updated_at = updated_at
    }
}

// Stage Events
public struct StageEvent: Codable {
    public let timestamp_ms: UInt64
    public let stage: StageDetails
}

public struct StageDetails: Codable {
    public let status: String
    public let details: [String: AnyCodable]?
}

public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intVal = value as? Int {
            try container.encode(intVal)
        } else if let doubleVal = value as? Double {
            try container.encode(doubleVal)
        } else if let stringVal = value as? String {
            try container.encode(stringVal)
        } else if let boolVal = value as? Bool {
            try container.encode(boolVal)
        }
    }
}

public struct SshConfigImportResponse: Codable {
    public let hosts: [Host]
    public let jumpHosts: [JumpHost]?
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case hosts
        case jumpHosts = "jump_hosts"
        case warnings
    }
}

public struct SSHKeyMetadata: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let fingerprint: String
    public let algorithm: String
}
