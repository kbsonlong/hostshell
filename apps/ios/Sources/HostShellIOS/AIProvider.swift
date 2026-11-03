import Foundation
import Security

enum AIProviderSettings {
    static let enabledKey = "ai.enabled"
    static let baseURLKey = "ai.openAICompatible.baseURL"
    static let modelKey = "ai.openAICompatible.model"
    static let defaultBaseURL = "https://api.openai.com/v1"

    static func endpoint(baseURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AIProviderError.invalidBaseURL
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw AIProviderError.invalidBaseURL
        }

        let rootPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [rootPath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else { throw AIProviderError.invalidBaseURL }
        return url
    }
}

enum AIProviderError: LocalizedError {
    case invalidBaseURL
    case emptyAPIKey
    case invalidResponse
    case httpStatus(Int)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "API 地址必须使用 HTTPS；仅允许 localhost 使用 HTTP。"
        case .emptyAPIKey:
            return "请先填写 API Key。"
        case .invalidResponse:
            return "服务返回的数据格式无法识别。"
        case .httpStatus(let status):
            return "服务请求失败（HTTP \(status)）。请检查地址、Key 和服务状态。"
        case .keychain(let status):
            return "无法安全保存 API Key（Keychain 错误 \(status)）。"
        }
    }
}

enum AIProviderKeychain {
    private static let service = "com.hostshell.ios.ai-provider"
    private static let account = "openai-compatible-api-key"

    static func loadAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AIProviderError.keychain(status) }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AIProviderError.keychain(addStatus) }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct OpenAICompatibleModel: Decodable, Identifiable {
    let id: String
}

private struct OpenAICompatibleModelsResponse: Decodable {
    let data: [OpenAICompatibleModel]
}

struct OpenAICompatibleProviderClient {
    let baseURL: String
    let apiKey: String

    func listModels() async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyAPIKey
        }
        let url = try AIProviderSettings.endpoint(baseURL: baseURL, path: "models")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode)
        }
        let models = try JSONDecoder().decode(OpenAICompatibleModelsResponse.self, from: data).data
            .map(\.id)
            .filter { !$0.isEmpty }
        guard !models.isEmpty else { throw AIProviderError.invalidResponse }
        return Array(Set(models)).sorted()
    }
}
