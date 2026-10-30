import SwiftUI

public struct TerminalAccessoryBar: View {
    public let onKey: (String) -> Void

    public var body: some View {
        HStack(spacing: 6) {
            Group {
                button(title: "ESC", action: { onKey("ESC") })
                button(title: "TAB", action: { onKey("TAB") })
                Divider().frame(height: 18)
                button(title: "Ctrl+C", action: { onKey("CTRL_C") }, isHighlighted: true)
                button(title: "Ctrl+D", action: { onKey("CTRL_D") })
                button(title: "Ctrl+Z", action: { onKey("CTRL_Z") })
                Divider().frame(height: 18)
            }

            Group {
                button(title: "|", action: { onKey("|") })
                button(title: "~", action: { onKey("~") })
                button(title: "/", action: { onKey("/") })
                button(title: "-", action: { onKey("-") })
                Divider().frame(height: 18)
            }

            Group {
                button(title: "↑", action: { onKey("UP") })
                button(title: "↓", action: { onKey("DOWN") })
                button(title: "←", action: { onKey("LEFT") })
                button(title: "→", action: { onKey("RIGHT") })
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func button(title: String, action: @escaping () -> Void, isHighlighted: Bool = false) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isHighlighted ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                .foregroundColor(isHighlighted ? .red : .primary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
