import SwiftUI

public struct MainView: View {
    @StateObject private var appVM = AppViewModel()
    @State private var activeSessionVM: SessionViewModel? = nil

    public var body: some View {
        NavigationSplitView {
            List(NavigationCategory.allCases, selection: $appVM.selectedCategory) { cat in
                NavigationLink(value: cat) {
                    Label(cat.rawValue, systemImage: cat.icon)
                }
            }
            .navigationTitle("HostShell")
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 200)
        } detail: {
            switch appVM.selectedCategory {
            case .hosts:
                HostListView(appVM: appVM)
            case .jumpHosts:
                JumpHostListView(appVM: appVM)
            case .keys:
                KeyManagementView(appVM: appVM)
            case .settings:
                SettingsView(appVM: appVM)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onChange(of: appVM.activeSessionHost) { host in
            if let h = host {
                let vm = SessionViewModel(host: h)
                activeSessionVM = vm
                vm.connect()
            } else {
                activeSessionVM?.disconnect()
                activeSessionVM = nil
            }
        }
        .sheet(item: $appVM.activeSessionHost) { host in
            if let vm = activeSessionVM {
                SessionSheetContent(sessionVM: vm) {
                    appVM.activeSessionHost = nil
                }
            }
        }
    }
}

private struct SessionSheetContent: View {
    @ObservedObject var sessionVM: SessionViewModel
    let onClose: () -> Void

    var body: some View {
        Group {
            if sessionVM.isConnected {
                TerminalView(sessionVM: sessionVM, onClose: onClose)
                    .frame(minWidth: 700, minHeight: 460)
            } else {
                ConnectionStageView(sessionVM: sessionVM, onCancel: onClose)
            }
        }
        .animation(.default, value: sessionVM.isConnected)
    }
}
