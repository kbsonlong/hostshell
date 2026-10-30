import Foundation

public enum ProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct = "direct"
    case proxyJump = "proxy_jump"
    case cloudflareAccess = "cloudflare_access"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .direct: return "直连 (Direct)"
        case .proxyJump: return "跳板机 (ProxyJump)"
        case .cloudflareAccess: return "零信任 (Cloudflare Access)"
        }
    }

    public var badgeName: String {
        switch self {
        case .direct: return "直连"
        case .proxyJump: return "ProxyJump"
        case .cloudflareAccess: return "Cloudflare"
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

    enum CodingKeys: String, CodingKey {
        case password
        case private_key
        case agent
    }

    private struct PrivateKeyPayload: Codable {
        let key_data: String
        let passphrase: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pwd = try? container.decode(String.self, forKey: .password) {
            self = .password(pwd)
        } else if let pk = try? container.decode(PrivateKeyPayload.self, forKey: .private_key) {
            self = .privateKey(keyData: pk.key_data, passphrase: pk.passphrase)
        } else {
            self = .agent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .password(let pwd):
            try container.encode(pwd, forKey: .password)
        case .privateKey(let keyData, let passphrase):
            try container.encode(PrivateKeyPayload(key_data: keyData, passphrase: passphrase), forKey: .private_key)
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

public struct Host: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var auth: AuthMethod
    public var proxy_mode: ProxyMode
    public var jump_host_ids: [String]
    public var cloudflare_config: CloudflareConfig?
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
        jump_host_ids: [String] = [],
        cloudflare_config: CloudflareConfig? = nil,
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
        self.jump_host_ids = jump_host_ids
        self.cloudflare_config = cloudflare_config
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
    public let warnings: [String]
}
