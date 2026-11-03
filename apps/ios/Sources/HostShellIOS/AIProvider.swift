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
    case emptyModel
    case emptyMessages
    case emptyCompletion

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
        case .emptyModel:
            return "请先选择或输入模型 ID。"
        case .emptyMessages:
            return "请输入要咨询的问题。"
        case .emptyCompletion:
            return "模型没有返回可显示的回答。"
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

struct AIChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

private struct OpenAICompatibleChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
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

    func makeChatCompletionRequest(model: String, messages: [AIChatMessage]) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyModel
        }
        guard messages.contains(where: { $0.role == "user" && !$0.content.isEmpty }) else {
            throw AIProviderError.emptyMessages
        }

        let url = try AIProviderSettings.endpoint(baseURL: baseURL, path: "chat/completions")
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: model, messages: messages))
        return request
    }

    func complete(model: String, messages: [AIChatMessage]) async throws -> String {
        let request = try makeChatCompletionRequest(model: model, messages: messages)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode)
        }
        let result = try JSONDecoder().decode(OpenAICompatibleChatResponse.self, from: data)
        guard let content = result.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { throw AIProviderError.emptyCompletion }
        return content
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [AIChatMessage]
        let temperature = 0.2
    }
}
