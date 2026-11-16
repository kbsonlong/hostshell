import SwiftUI

public struct JumpHostListView: View {
    @ObservedObject var appVM: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("跳板机资产库")
                        .font(.title2.weight(.bold))
                    Text("统一管理可复用的 SSH 跳板节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: { appVM.newJumpHost() }) {
                    Label("添加跳板机", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(HostShellPalette.canvas(colorScheme))

            Divider()

            if appVM.jumpHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("暂无跳板机资产")
                        .font(.headline)
                    Text("跳板机（Bastion / Jump Host）可在此统一配置并复用于任意主机目标，支持多跳穿透与远程 DNS 解析。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("新建首个跳板机") {
                        appVM.newJumpHost()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                    ForEach(appVM.jumpHosts) { jh in
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(HostShellPalette.blue)
                                .frame(width: 38, height: 38)
                                .background(HostShellPalette.blue.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 9))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(jh.name)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("\(jh.username)@\(jh.hostname):\(jh.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer(minLength: 12)

                            if case .agent = jh.auth {
                                assetBadge("SSH Agent", color: HostShellPalette.teal)
                            } else {
                                assetBadge("被 \(referenceCount(for: jh)) 台主机引用", color: .secondary)
                            }

                            Button {
                                appVM.connect(to: jh)
                            } label: {
                                Label("连接", systemImage: "terminal")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("编辑") {
                                appVM.editJumpHost(jh)
                            }
                            .controlSize(.small)

                            Button(role: .destructive) {
                                appVM.deleteJumpHost(jh)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)

                        Divider().padding(.leading, 70)
                    }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(NSColor.underPageBackgroundColor))
            }
        }
        .sheet(isPresented: $appVM.isShowingJumpHostEditor) {
            JumpHostEditSheet(appVM: appVM, jumpHost: appVM.editingJumpHost)
        }
    }

    private func referenceCount(for jumpHost: JumpHost) -> Int {
        appVM.hosts.filter { $0.jump_host_ids.contains(jumpHost.id) }.count
    }

    private func assetBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
