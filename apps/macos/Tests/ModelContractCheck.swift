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
        print("macOS wire model: auth + proxy_command + jump_hosts decode/encode OK")
    }
}
