import Foundation

public struct ShellCompletionCandidate: Identifiable, Equatable {
    public let id: String
    public let value: String
    public let description: String?

    public init(id: String, value: String, description: String? = nil) {
        self.id = id
        self.value = value
        self.description = description
    }
}

public struct ShellCompletionContext: Equatable {
    public let line: String
    public let cursor: Int
    public let isInteractiveShell: Bool

    public init(line: String, cursor: Int, isInteractiveShell: Bool) {
        self.line = line
        self.cursor = cursor
        self.isInteractiveShell = isInteractiveShell
    }
}

public enum ShellCompletionPolicy {
    public static func shouldUseHostCandidates(_ context: ShellCompletionContext) -> Bool {
        guard context.isInteractiveShell else { return false }
        guard context.cursor >= 0, context.cursor <= context.line.utf16.count else { return false }
        return !context.line.contains("\u{1B}")
    }
}