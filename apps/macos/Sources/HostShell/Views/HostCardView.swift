import SwiftUI

public struct HostCardView: View {
    public let host: Host
    public let onConnect: () -> Void
    public let onEdit: () -> Void
    public let onDelete: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

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

            // Mode & Info Badges
            HStack(spacing: 6) {
                proxyBadge(for: host.proxy_mode)

                if host.proxy_mode == .proxyJump && !host.jump_host_ids.isEmpty {
                    Text("\(host.jump_host_ids.count) 跳")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                ForEach(host.tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
            }

            Spacer(minLength: 4)

            // Connect Button
            Button(action: onConnect) {
                HStack {
                    Image(systemName: "terminal")
                    Text("连接终端")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func proxyBadge(for mode: ProxyMode) -> some View {
        switch mode {
        case .direct:
            Label("直连", systemImage: "link")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .foregroundColor(.green)
                .cornerRadius(4)
        case .proxyJump:
            Label("跳板机", systemImage: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .cornerRadius(4)
        case .proxyCommand:
            Label("ProxyCommand", systemImage: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .foregroundColor(.orange)
                .cornerRadius(4)
        case .cloudflareAccess:
            Label("Cloudflare", systemImage: "shield.checkerboard")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.15))
                .foregroundColor(.purple)
                .cornerRadius(4)
        }
    }
}
