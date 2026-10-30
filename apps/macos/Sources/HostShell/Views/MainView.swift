import SwiftUI

public struct MainView: View {
    @StateObject private var appVM = AppViewModel()
    @State private var activeSessionVM: SessionViewModel? = nil
    @State private var activeJumpSessionVM: SessionViewModel? = nil

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
        .sheet(isPresented: Binding(
            get: { appVM.activeJumpSessionVM != nil },
            set: { if !$0 { appVM.activeJumpSessionVM = nil } }
        )) {
            if let vm = appVM.activeJumpSessionVM {
                Group {
                    if vm.isConnected {
                        TerminalView(sessionVM: vm) {
                            appVM.activeJumpSessionVM = nil
                        }
                        .frame(minWidth: 700, minHeight: 460)
                    } else {
                        ConnectionStageView(sessionVM: vm) {
                            appVM.activeJumpSessionVM = nil
                        }
                    }
                }
            }
        }
        .sheet(item: $appVM.activeSessionHost) { host in
            if let vm = activeSessionVM {
                Group {
                    if vm.isConnected {
                        TerminalView(sessionVM: vm) {
                            appVM.activeSessionHost = nil
                        }
                        .frame(minWidth: 700, minHeight: 460)
                    } else {
                        ConnectionStageView(sessionVM: vm) {
                            appVM.activeSessionHost = nil
                        }
                    }
                }
            }
        }
    }
}
