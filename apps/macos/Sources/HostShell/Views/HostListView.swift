import SwiftUI

public struct HostListView: View {
    @ObservedObject var appVM: AppViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16)
    ]

    public var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索主机名称、IP 或标签...", text: $appVM.searchQuery)
                        .textFieldStyle(.plain)
                    if !appVM.searchQuery.isEmpty {
                        Button(action: { appVM.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .frame(maxWidth: 320)

                Spacer()

                Button(action: { appVM.isShowingImportSheet = true }) {
                    Label("导入配置 (~/.ssh/config)", systemImage: "square.and.arrow.down")
                }

                Button(action: { appVM.newHost() }) {
                    Label("新建主机", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if appVM.filteredHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    if appVM.hosts.isEmpty {
                        Text("还没有添加任何主机")
                            .font(.headline)
                        Text("点击右上角「新建主机」或「导入配置」，支持直连、ProxyJump 跳板机与 Cloudflare Access 零信任链路。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button("立即新建主机") {
                            appVM.newHost()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    } else {
                        Text("未找到匹配的主机")
                            .font(.headline)
                        Button("清除搜索") {
                            appVM.searchQuery = ""
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(appVM.filteredHosts) { host in
                            HostCardView(
                                host: host,
                                onConnect: { appVM.connect(to: host) },
                                onEdit: { appVM.editHost(host) },
                                onDelete: { appVM.deleteHost(host) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $appVM.isShowingHostEditor) {
            HostEditSheet(appVM: appVM, host: appVM.editingHost)
        }
        .sheet(isPresented: $appVM.isShowingImportSheet) {
            SshConfigImportSheet(appVM: appVM)
        }
    }
}
