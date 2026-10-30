import SwiftUI

public struct JumpHostListView: View {
    @ObservedObject var appVM: AppViewModel

    public var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                Text("跳板机资产库")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { appVM.newJumpHost() }) {
                    Label("添加跳板机", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

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
                List {
                    ForEach(appVM.jumpHosts) { jh in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(jh.name)
                                    .font(.headline)
                                Text("\(jh.username)@\(jh.hostname):\(jh.port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if case .agent = jh.auth {
                                Text("SSH Agent")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
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
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .sheet(isPresented: $appVM.isShowingJumpHostEditor) {
            JumpHostEditSheet(appVM: appVM, jumpHost: appVM.editingJumpHost)
        }
    }
}
