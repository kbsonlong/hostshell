import Foundation

@main
enum IOSModelContractCheck {
    static func main() throws {
        let payload = #"""
        {
          "hosts": [{
            "id": "host-direct",
            "name": "direct",
            "hostname": "direct.example.test",
            "port": 22,
            "username": "engineer",
            "auth": {"password": "test-password"},
            "proxy_mode": "direct",
            "jump_host_ids": [],
            "cloudflare_config": null,
            "tags": [],
            "last_connected_at": null,
            "created_at": 1,
            "updated_at": 1
          }, {
            "id": "host-office",
            "name": "office",
            "hostname": "m1.example.test",
            "port": 22,
            "username": "engineer",
            "auth": "agent",
            "proxy_mode": "proxy_command",
            "jump_host_ids": [],
            "cloudflare_config": null,
            "proxy_command": "cloudflared access ssh --hostname %h",
            "tags": ["imported"],
            "last_connected_at": null,
            "created_at": 1,
            "updated_at": 1
          }],
          "jump_hosts": [{
            "id": "jump-1",
            "name": "jump",
            "hostname": "jump.example.test",
            "port": 32200,
            "username": "engineer",
            "auth": "agent"
          }],
          "warnings": []
        }
        """#
        let response = try JSONDecoder().decode(SshConfigImportResponse.self, from: Data(payload.utf8))
        precondition(response.hosts.count == 2)
        precondition(response.hosts[0].auth == .password("test-password"))
        precondition(response.hosts[1].auth == .agent)
        precondition(response.hosts[1].proxy_mode == .proxyCommand)
        precondition(response.jumpHosts?.count == 1)
        precondition(response.jumpHosts?[0].auth == .agent)
        let encoded = try JSONEncoder().encode(response.hosts)
        let decodedAgain = try JSONDecoder().decode([Host].self, from: encoded)
        precondition(decodedAgain == response.hosts)
        var savedKeyHost = response.hosts[0]
        savedKeyHost.auth = .keyRef(id: "key-1")
        let savedKeyHostData = try JSONEncoder().encode(savedKeyHost)
        let restoredHost = try JSONDecoder().decode(Host.self, from: savedKeyHostData)
        precondition(restoredHost.auth == .keyRef(id: "key-1"))
        let keyData = Data(#"[{"id":"key-1","name":"work","fingerprint":"SHA256:example","algorithm":"ssh-ed25519"}]"#.utf8)
        let keys = try JSONDecoder().decode([SSHKeyMetadata].self, from: keyData)
        precondition(keys.count == 1 && keys[0].id == "key-1" && keys[0].name == "work")
        let preferences = TerminalPreferences(
            fontSize: 30,
            fontFamily: .jetBrainsMono,
            theme: .light,
            cursorStyle: .bar,
            emulation: .tmux256color,
            scrollbackLines: 20,
            keepaliveSeconds: 1
        )
        precondition(preferences.fontSize == 24)
        precondition(preferences.scrollbackLines == 100)
        precondition(preferences.keepaliveSeconds == 5)
        let connectPayload = try preferences.connectPayload(from: JSONEncoder().encode(response.hosts[0]))
        let connectObject = try JSONSerialization.jsonObject(with: Data(connectPayload.utf8)) as! [String: Any]
        let terminalSettings = connectObject["terminal_settings"] as! [String: Any]
        precondition(terminalSettings["term_type"] as? String == "tmux-256color")
        precondition(terminalSettings["keepalive_seconds"] as? Int == 5)
        let modelsURL = try AIProviderSettings.endpoint(
            baseURL: "https://ai.example.test/v1/",
            path: "/models"
        )
        precondition(modelsURL.absoluteString == "https://ai.example.test/v1/models")
        let localModelsURL = try AIProviderSettings.endpoint(
            baseURL: "http://localhost:1234/v1",
            path: "models"
        )
        precondition(localModelsURL.absoluteString == "http://localhost:1234/v1/models")
        let client = OpenAICompatibleProviderClient(baseURL: "https://ai.example.test/v1", apiKey: "contract-test-key")
        let completionRequest = try client.makeChatCompletionRequest(
            model: "example-model",
            messages: [AIChatMessage(role: "user", content: "explain this error")]
        )
        precondition(completionRequest.url?.absoluteString == "https://ai.example.test/v1/chat/completions")
        precondition(completionRequest.httpMethod == "POST")
        precondition(completionRequest.value(forHTTPHeaderField: "Authorization") == "Bearer contract-test-key")
        let completionBody = try JSONSerialization.jsonObject(with: completionRequest.httpBody!) as! [String: Any]
        precondition(completionBody["model"] as? String == "example-model")
        let completionMessages = completionBody["messages"] as! [[String: String]]
        precondition(completionMessages.first?["content"] == "explain this error")
        do {
            _ = try client.makeChatCompletionRequest(
                model: "example-model",
                messages: [AIChatMessage(role: "user", content: String(repeating: "x", count: 70_000))]
            )
            preconditionFailure("Oversized AI requests must be rejected")
        } catch AIProviderError.contextTooLong {
            // Expected: request bodies are capped to keep conversation context bounded.
        }
        let privateKeyStart = ["-----BEGIN OPENSSH ", "PRIVATE KEY-----"].joined()
        let privateKeyFixture = [
            privateKeyStart,
            "fixture-data",
            privateKeyStart.replacingOccurrences(of: "BEGIN", with: "END")
        ].joined(separator: "\n")
        let passwordLine = ["PASS", "WORD"].joined() + "=example-value"
        let authLine = ["Authoriza", "tion: Bearer example-token"].joined()
        let cookieLine = ["Set-", "Cookie: session=example-cookie"].joined()
        let redactedContext = AIProviderSettings.redactSensitiveText(
            [passwordLine, authLine, cookieLine, privateKeyFixture].joined(separator: "\n")
        )
        precondition(!redactedContext.contains("example-value"))
        precondition(!redactedContext.contains("example-token"))
        precondition(!redactedContext.contains("example-cookie"))
        precondition(!redactedContext.contains("fixture-data"))
        precondition(redactedContext.contains("[私钥内容已脱敏]"))
        do {
            _ = try AIProviderSettings.endpoint(baseURL: "http://ai.example.test/v1", path: "models")
            preconditionFailure("Non-loopback HTTP providers must be rejected")
        } catch AIProviderError.invalidBaseURL {
            // Expected: remote provider endpoints must use HTTPS.
        }
        print("iOS wire model + terminal settings contract OK")
    }
}
