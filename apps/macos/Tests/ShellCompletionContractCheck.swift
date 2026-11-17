import Foundation

@main
enum ShellCompletionContractCheck {
    static func eventJSON() -> Data {
        let object: [String: Any] = [
            "line": "git ch",
            "cursor": 6,
            "interactive": true,
            "candidates": [
                ["id": "1", "value": "erry-pick", "description": "apply commit"]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func main() {
        let titleStream = Array("before\u{1B}kwhoami\u{1B}\\zengshenglong\r\n".utf8)
        for split in 0...titleStream.count {
            var filter = ScreenTitleStreamFilter()
            let visible = filter.consume(Array(titleStream[..<split])) + filter.consume(Array(titleStream[split...]))
            precondition(String(decoding: visible, as: UTF8.self) == "beforezengshenglong\r\n")
        }
        let otherOSC = Array("\u{1B}]2;literal\u{1B}ktext\u{1B}\\after".utf8)
        var filter = ScreenTitleStreamFilter()
        precondition(filter.consume(otherOSC) == otherOSC)

        let prefix = Array("\u{1B}]777;hostshell.completion;".utf8)
        let suffix = Array("\u{07}".utf8)
        let visible = Array("prompt$ ".utf8)
        let payload = prefix + Array(eventJSON()) + suffix
        var parser = ShellCompletionStreamParser()

        let first = parser.consume(visible + Array(payload.prefix(11)))
        precondition(first.visibleBytes == visible)
        precondition(first.events.isEmpty)

        let second = parser.consume(Array(payload.dropFirst(11)))
        precondition(second.visibleBytes.isEmpty)
        precondition(second.events.count == 1)
        precondition(second.events[0].context.line == "git ch")
        precondition(second.events[0].candidates[0].value == "erry-pick")

        let invalid: [String: Any] = [
            "line": "\u{1B}[31munsafe",
            "cursor": 11,
            "interactive": true,
            "candidates": [["id": "x", "value": "ignored"]]
        ]
        let invalidPayload = try! JSONSerialization.data(withJSONObject: invalid)
        let invalidResult = parser.consume(prefix + invalidPayload + suffix)
        precondition(invalidResult.events.isEmpty)
        precondition(invalidResult.visibleBytes.isEmpty)

        let stTerminated = prefix + eventJSON() + [0x1B, 0x5C]
        let stResult = parser.consume(stTerminated)
        precondition(stResult.events.count == 1)
        print("macOS shell completion parser contract OK")
    }
}
