import SwiftUI

public struct HostListView: View {
    @ObservedObject var appVM: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 14)
    ]

    public var body: some View {
        VStack(spacing: 0) {
            // Search and asset actions
            pageHeader

            Divider()

            if appVM.assetLoadError != nil && appVM.hosts.isEmpty {
                errorState
            } else if appVM.filteredHosts.isEmpty {
                emptyState
            } else {
                hostGrid
            }
        }
        .sheet(isPresented: $appVM.isShowingHostEditor) {
            HostEditSheet(appVM: appVM, host: appVM.editingHost)
        }
        .sheet(isPresented: $appVM.isShowingImportSheet) {
            SshConfigImportSheet(appVM: appVM)
        }
        .background(HostShellPalette.workspace(colorScheme))
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
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
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(HostShellPalette.panel(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 390)

            Spacer(minLength: 12)

            Button(action: { appVM.isShowingImportSheet = true }) {
                Label("导入配置", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)

            Button(action: { appVM.newHost() }) {
                Label("新建主机", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(HostShellPalette.canvas(colorScheme))
    }

    // MARK: - Host Grid

    private var hostGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(appVM.filteredHosts) { host in
                    HostCardView(
                        host: host,
                        onConnect: { appVM.connect(to: host) },
                        onEdit: { appVM.editHost(host) },
                        onDelete: { appVM.deleteHost(host) }
                    )
                }
            }
            .padding(18)
        }
        .background(HostShellPalette.workspace(colorScheme))
    }

    // MARK: - Empty / Error States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: appVM.hosts.isEmpty ? "server.rack" : "magnifyingglass")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.6))

            if appVM.hosts.isEmpty {
                Text("还没有添加任何主机")
                    .font(.headline)
                Text("点击右上角「新建主机」或「导入配置」，\n支持直连、ProxyJump 跳板机与 Cloudflare Access 零信任链路。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                HStack(spacing: 12) {
                    Button(action: { appVM.newHost() }) {
                        Label("新建主机", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { appVM.isShowingImportSheet = true }) {
                        Label("导入配置", systemImage: "square.and.arrow.down")
                    }
                }
                .padding(.top, 4)
            } else {
                Text("未找到匹配的主机")
                    .font(.headline)
                Button("清除搜索") { appVM.searchQuery = "" }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("主机列表不可用")
                .font(.headline)
                .foregroundColor(.secondary)
            Button("重试读取") { appVM.loadData() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
