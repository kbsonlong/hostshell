import Foundation

public enum ShellProviderEnvironment {
    public static let optInEnvironment: [String: String] = [
        "HOSTSHELL_COMPLETION": "1",
        "HOSTSHELL_COMPLETION_PROTOCOL": "osc777",
        "HOSTSHELL_COMPLETION_PROVIDER_VERSION": "1"
    ]

    public static func merged(_ base: [String], shellExecutable: String) -> [String] {
        guard ShellProvider.detect(executable: shellExecutable) != nil else { return base }
        var values = base
        for (key, value) in optInEnvironment {
            values.removeAll { $0.hasPrefix("\(key)=") }
            values.append("\(key)=\(value)")
        }
        return values
    }
}
