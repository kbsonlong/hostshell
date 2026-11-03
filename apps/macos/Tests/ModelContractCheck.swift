import Foundation

@main
enum ModelContractCheck {
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
            "proxy_command": null,
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
        do {
            _ = try AIProviderSettings.endpoint(baseURL: "http://ai.example.test/v1", path: "models")
            preconditionFailure("Remote HTTP AI providers must be rejected")
        } catch AIProviderError.invalidBaseURL {
            // Expected: non-loopback provider endpoints must use HTTPS.
        }
        let client = OpenAICompatibleProviderClient(baseURL: "https://ai.example.test/v1", apiKey: "contract-test-key")
        let request = try client.makeRequest(
            model: "example-model",
            messages: [AIChatMessage(role: "user", content: "explain this error")]
        )
        precondition(request.url?.absoluteString == "https://ai.example.test/v1/chat/completions")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer contract-test-key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["model"] as? String == "example-model")
        let messages = body["messages"] as! [[String: String]]
        precondition(messages.first?["content"] == "explain this error")
        do {
            _ = try client.makeRequest(
                model: "example-model",
                messages: [AIChatMessage(role: "user", content: String(repeating: "x", count: 70_000))]
            )
            preconditionFailure("Oversized AI request must be rejected")
        } catch AIProviderError.contextTooLong {
            // Expected: request body is capped at 64 KiB.
        }
        print("macOS wire model + terminal settings contract OK")
    }
}
