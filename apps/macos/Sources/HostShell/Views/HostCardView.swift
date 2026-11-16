import SwiftUI

public struct HostCardView: View {
    public let host: Host
    public let onConnect: () -> Void
    public let onEdit: () -> Void
    public let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top section: identity + menu
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 4)

                Menu {
                    Button("编辑主机", action: onEdit)
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("删除主机", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.bottom, 8)

            // Badges row
            HStack(spacing: 6) {
                proxyBadge(for: host.proxy_mode)

                if host.proxy_mode == .proxyJump && !host.jump_host_ids.isEmpty {
                    badge(
                        text: "\(host.jump_host_ids.count) 跳",
                        icon: "arrow.triangle.branch",
                        color: HostShellPalette.blue
                    )
                }

                if let forwards = host.port_forwards, !forwards.isEmpty {
                    badge(
                        text: "\(forwards.count) 隧道",
                        icon: "point.3.connected.trianglepath.dotted",
                        color: HostShellPalette.teal
                    )
                }

            }

            // Tags
            if !host.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(host.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                    if host.tags.count > 3 {
                        Text("+\(host.tags.count - 3)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 10)

            // Connect button
            Button(action: onConnect) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13))
                    Text("连接终端")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(HostShellPalette.blue)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(HostShellPalette.panel(colorScheme))
                .shadow(
                    color: Color.black.opacity(isHovered ? 0.08 : 0.025),
                    radius: isHovered ? 7 : 2,
                    x: 0,
                    y: isHovered ? 3 : 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isHovered ? HostShellPalette.blue.opacity(0.42) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Proxy Mode Visuals

    private func proxyModeSymbol(for mode: ProxyMode) -> String {
        switch mode {
        case .direct: return "link"
        case .proxyJump: return "arrow.triangle.branch"
        case .proxyCommand: return "terminal"
        case .cloudflareAccess: return "shield.checkerboard"
        }
    }

    private func proxyModeColor(for mode: ProxyMode) -> Color {
        HostShellPalette.proxyColor(mode)
    }

    @ViewBuilder
    private func proxyBadge(for mode: ProxyMode) -> some View {
        let color = proxyModeColor(for: mode)
        HStack(spacing: 3) {
            Image(systemName: proxyModeSymbol(for: mode))
                .font(.system(size: 9))
            Text(mode.badgeName)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .cornerRadius(4)
    }

    private func badge(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .cornerRadius(4)
    }

}
