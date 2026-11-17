import Foundation
import SwiftUI

/// Removes GNU Screen's ESC k title string, which SwiftTerm treats as text.
/// Other terminal control strings pass through unchanged, even across chunks.
public struct ScreenTitleStreamFilter {
    private enum State { case normal, escape, controlString, controlStringEscape, title, titleEscape }
    private var state = State.normal

    public init() {}

    public mutating func consume(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8]()
        for byte in bytes {
            switch state {
            case .normal:
                if byte == 0x1b { state = .escape }
                else { output.append(byte) }
            case .escape:
                if byte == 0x6b { state = .title }
                else {
                    output.append(0x1b)
                    if byte == 0x1b { state = .escape }
                    else {
                        output.append(byte)
                        state = [0x5d, 0x50, 0x5f, 0x5e, 0x58].contains(byte) ? .controlString : .normal
                    }
                }
            case .controlString:
                output.append(byte)
                if byte == 0x1b { state = .controlStringEscape }
                else if byte == 0x07 || byte == 0x18 || byte == 0x1a { state = .normal }
            case .controlStringEscape:
                output.append(byte)
                if byte == 0x5c || byte == 0x18 || byte == 0x1a { state = .normal }
                else if byte != 0x1b { state = .controlString }
            case .title:
                if byte == 0x1b { state = .titleEscape }
                else if byte == 0x18 || byte == 0x1a { state = .normal }
            case .titleEscape:
                if byte == 0x5c || byte == 0x18 || byte == 0x1a { state = .normal }
                else if byte != 0x1b { state = .title }
            }
        }
        return output
    }
}

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

/// Parses completion data emitted by an explicitly installed shell integration.
/// The integration uses OSC 777 and never runs a command on the user's PTY.
public struct ShellCompletionEvent: Equatable {
    public let context: ShellCompletionContext
    public let candidates: [ShellCompletionCandidate]

    public init(context: ShellCompletionContext, candidates: [ShellCompletionCandidate]) {
        self.context = context
        self.candidates = candidates
    }
}

public struct ShellCompletionParseResult {
    public let visibleBytes: [UInt8]
    public let events: [ShellCompletionEvent]

    public init(visibleBytes: [UInt8], events: [ShellCompletionEvent]) {
        self.visibleBytes = visibleBytes
        self.events = events
    }
}

public struct ShellCompletionStreamParser {
    private static let prefix = Array("\u{1B}]777;hostshell.completion;".utf8)
    private static let bel: UInt8 = 0x07
    private static let esc: UInt8 = 0x1B
    private static let backslash: UInt8 = 0x5C
    private var buffer = [UInt8]()

    public init() {}

    /// Removes HostShell OSC 777 events before bytes reach the terminal emulator.
    /// Incomplete prefixes/events remain buffered until the next output chunk.
    public mutating func consume(_ bytes: [UInt8]) -> ShellCompletionParseResult {
        buffer.append(contentsOf: bytes)
        var visible = [UInt8]()
        var events = [ShellCompletionEvent]()

        while !buffer.isEmpty {
            guard let startRange = buffer.firstRange(of: Self.prefix) else {
                let keep = Self.longestSuffixMatchingPrefix(buffer)
                if buffer.count > keep {
                    visible.append(contentsOf: buffer.prefix(buffer.count - keep))
                    buffer.removeFirst(buffer.count - keep)
                }
                break
            }
            let start = startRange.lowerBound
            if start > 0 {
                visible.append(contentsOf: buffer.prefix(start))
                buffer.removeFirst(start)
            }
            guard let end = Self.terminator(in: buffer, from: Self.prefix.count) else { break }
            let payload = Data(buffer[Self.prefix.count..<end.payloadEnd])
            buffer.removeFirst(end.consumedEnd)
            if let event = Self.decode(payload) { events.append(event) }
        }

        if buffer.count > 64 * 1024 {
            buffer = Array(buffer.suffix(Self.prefix.count - 1))
        }
        return ShellCompletionParseResult(visibleBytes: visible, events: events)
    }

    public mutating func feed(_ bytes: [UInt8]) -> [ShellCompletionEvent] {
        consume(bytes).events
    }

    private struct Terminator { let payloadEnd: Int; let consumedEnd: Int }

    private static func terminator(in bytes: [UInt8], from: Int) -> Terminator? {
        guard from <= bytes.count else { return nil }
        for i in from..<bytes.count {
            if bytes[i] == Self.bel { return Terminator(payloadEnd: i, consumedEnd: i + 1) }
            if bytes[i] == Self.esc, i + 1 < bytes.count, bytes[i + 1] == Self.backslash {
                return Terminator(payloadEnd: i, consumedEnd: i + 2)
            }
        }
        return nil
    }

    private static func longestSuffixMatchingPrefix(_ bytes: [UInt8]) -> Int {
        let maxLength = min(bytes.count, prefix.count - 1)
        for length in stride(from: maxLength, through: 1, by: -1) {
            if Array(bytes.suffix(length)) == Array(prefix.prefix(length)) { return length }
        }
        return 0
    }

    private static func decode(_ payload: Data) -> ShellCompletionEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let root = object as? [String: Any],
              let line = root["line"] as? String,
              let cursor = root["cursor"] as? Int,
              let interactive = root["interactive"] as? Bool,
              let rawCandidates = root["candidates"] as? [[String: Any]],
              rawCandidates.count <= 100,
              line.utf8.count <= 16 * 1024,
              ShellCompletionPolicy.shouldUseHostCandidates(
                ShellCompletionContext(line: line, cursor: cursor, isInteractiveShell: interactive)
              ) else { return nil }
        let candidates = rawCandidates.compactMap { item -> ShellCompletionCandidate? in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let value = item["value"] as? String,
                  value.utf8.count <= 4096,
                  !value.contains("\u{1B}") else { return nil }
            return ShellCompletionCandidate(id: id, value: value, description: item["description"] as? String)
        }
        return ShellCompletionEvent(
            context: ShellCompletionContext(line: line, cursor: cursor, isInteractiveShell: interactive),
            candidates: candidates
        )
    }
}

public struct ShellCompletionMenu: View {
    public let candidates: [ShellCompletionCandidate]
    public let onSelect: (ShellCompletionCandidate) -> Void
    public let onDismiss: () -> Void

    public init(candidates: [ShellCompletionCandidate], onSelect: @escaping (ShellCompletionCandidate) -> Void, onDismiss: @escaping () -> Void) {
        self.candidates = candidates
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("补全").font(.caption.weight(.semibold))
                Spacer()
                Button("取消", action: onDismiss).buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            ForEach(candidates) { candidate in
                Button { onSelect(candidate) } label: {
                    HStack(spacing: 8) {
                        Text(candidate.value).font(.system(.body, design: .monospaced)).lineLimit(1)
                        if let description = candidate.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 280, maxWidth: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8)
    }
}
