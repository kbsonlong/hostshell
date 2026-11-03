import SwiftUI
import Combine
import Foundation
import SwiftTerm
import UIKit
import AudioToolbox
import UniformTypeIdentifiers
import Network

@_silgen_name("hostshell_engine_init") private func c_engine_init() -> OpaquePointer?
@_silgen_name("hostshell_engine_free") private func c_engine_free(_ engine: OpaquePointer?)
@_silgen_name("hostshell_list_keys") private func c_list_keys(_ engine: OpaquePointer?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_add_key") private func c_add_key(_ engine: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_delete_key") private func c_delete_key(_ engine: OpaquePointer?, _ id: UnsafePointer<CChar>?) -> Int32
@_silgen_name("hostshell_free_string") private func c_free_string(_ ptr: UnsafeMutablePointer<CChar>?)
@_silgen_name("hostshell_list_hosts") private func c_list_hosts(_ engine: OpaquePointer?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_save_host") private func c_save_host(_ engine: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> Int32
@_silgen_name("hostshell_delete_host") private func c_delete_host(_ engine: OpaquePointer?, _ id: UnsafePointer<CChar>?) -> Int32
@_silgen_name("hostshell_list_jump_hosts") private func c_list_jumps(_ engine: OpaquePointer?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_save_jump_host") private func c_save_jump(_ engine: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> Int32
@_silgen_name("hostshell_import_ssh_config") private func c_import_config(_ engine: OpaquePointer?, _ text: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_connect_with_auth_input") private func c_connect(_ engine: OpaquePointer?, _ host: UnsafePointer<CChar>?, _ cols: UInt32, _ rows: UInt32, _ autoAccept: Bool, _ stage: StageCallback?, _ output: OutputCallback?, _ authInput: AuthInputCallback?, _ ctx: UnsafeMutableRawPointer?) -> OpaquePointer?
@_silgen_name("hostshell_session_write") private func c_session_write(_ session: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Int32
@_silgen_name("hostshell_session_resize") private func c_session_resize(_ session: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Int32
@_silgen_name("hostshell_session_close") private func c_session_close(_ session: OpaquePointer?)
@_silgen_name("hostshell_cancel_connect") private func c_cancel_connect(_ userData: UnsafeMutableRawPointer?)
@_silgen_name("hostshell_finish_connect") private func c_finish_connect(_ userData: UnsafeMutableRawPointer?)

private typealias StageCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias OutputCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void
private typealias AuthInputCallback = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool,
    UnsafeMutablePointer<CChar>?, Int, UnsafeMutableRawPointer?
) -> Int32

struct ImportResponse: Decodable {
    let hosts: [Host]
    let jump_hosts: [JumpHost]?
    let warnings: [String]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [Host] = []
    @Published var jumps: [JumpHost] = []
    @Published var keys: [SSHKeyMetadata] = []
    @Published var error: String?
    private var engine = c_engine_init()

    init() { reload() }
    deinit { c_engine_free(engine) }

    func reload() {
        hosts = decodeArray(c_list_hosts(engine))
        jumps = decodeArray(c_list_jumps(engine))
        keys = decodeArray(c_list_keys(engine))
    }

    func addKey(name: String, key: String, passphrase: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["name": name, "key_data": key, "passphrase": passphrase]),
              let json = String(data: data, encoding: .utf8),
              let ptr = json.withCString({ c_add_key(engine, $0) }) else { return "保存失败" }
        defer { c_free_string(ptr) }
        guard let result = try? JSONSerialization.jsonObject(with: Data(String(cString: ptr).utf8)) as? [String: Any] else { return "保存失败" }
        if result["ok"] as? Bool == true { reload(); return nil }
        return result["error"] as? String ?? "保存失败"
    }

    func deleteKey(_ id: String) -> String? {
        let rc = id.withCString { c_delete_key(engine, $0) }
        if rc == 0 { reload(); return nil }
        return rc == -2 ? "该证书仍被主机或 Agent 转发使用，请先解除引用。" : "删除失败，请检查 Keychain。"
    }

    @discardableResult
    func save(_ host: Host) -> Bool {
        guard !hosts.contains(where: { $0.id != host.id && $0.name == host.name }) else {
            error = "已有同名主机，请使用其他名称。"
            return false
        }
        guard let data = try? JSONEncoder().encode(host), let json = String(data: data, encoding: .utf8) else {
            error = "无法编码主机配置。"
            return false
        }
        let rc = json.withCString { c_save_host(engine, $0) }
        if rc != 0 { error = "保存主机失败（错误码 \(rc)）"; return false }
        reload()
        return true
    }

    func save(_ jump: JumpHost) {
        guard let data = try? JSONEncoder().encode(jump), let json = String(data: data, encoding: .utf8) else { return }
        let rc = json.withCString { c_save_jump(engine, $0) }
        if rc != 0 { error = "保存跳板机失败（错误码 \(rc)）" }
        reload()
    }

    func delete(_ host: Host) {
        _ = host.id.withCString { c_delete_host(engine, $0) }
        reload()
    }

    func importConfig(_ text: String) -> ImportResponse? {
        guard let ptr = text.withCString({ c_import_config(engine, $0) }) else { return nil }
        defer { c_free_string(ptr) }
        return try? JSONDecoder().decode(ImportResponse.self, from: Data(String(cString: ptr).utf8))
    }

    func connect(
        _ host: Host,
        onStage: @escaping (String) -> Void,
        onOutput: @escaping (Data) -> Void,
        onAuthInput: @escaping (String, String, String, Bool) -> String?,
        onConnectStarted: ((IOSConnectCancellation) -> Void)? = nil,
        terminalPreferences: TerminalPreferences = .load()
    ) -> Session {
        let context = IOSCallbacks(onStage: onStage, onOutput: onOutput, onAuthInput: onAuthInput)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        guard let data = try? JSONEncoder().encode(host),
              let json = try? terminalPreferences.connectPayload(from: data) else {
            Unmanaged<IOSCallbacks>.fromOpaque(opaque).release()
            return Session(pointer: nil)
        }
        let cancellation = IOSConnectCancellation(userData: opaque)
        onConnectStarted?(cancellation)
        let pointer = json.withCString {
            c_connect(engine, $0, 80, 24, true, iosStageCallback, iosOutputCallback, iosAuthInputCallback, opaque)
        }
        cancellation.finish()
        if pointer == nil { Unmanaged<IOSCallbacks>.fromOpaque(opaque).release() }
        return Session(pointer: pointer, context: pointer == nil ? nil : opaque)
    }

    private func decodeArray<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>?) -> [T] {
        guard let ptr else { return [] }
        defer { c_free_string(ptr) }
        return (try? JSONDecoder().decode([T].self, from: Data(String(cString: ptr).utf8))) ?? []
    }
}

private final class IOSCallbacks {
    let onStage: (String) -> Void
    let onOutput: (Data) -> Void
    let onAuthInput: (String, String, String, Bool) -> String?
    init(
        onStage: @escaping (String) -> Void,
        onOutput: @escaping (Data) -> Void,
        onAuthInput: @escaping (String, String, String, Bool) -> String?
    ) {
        self.onStage = onStage
        self.onOutput = onOutput
        self.onAuthInput = onAuthInput
    }
}

private let iosStageCallback: StageCallback = { json, context in
    guard let json, let context else { return }
    let box = Unmanaged<IOSCallbacks>.fromOpaque(context).takeUnretainedValue()
    box.onStage(String(cString: json))
}
private let iosOutputCallback: OutputCallback = { bytes, length, context in
    guard let bytes, length > 0, let context else { return }
    let box = Unmanaged<IOSCallbacks>.fromOpaque(context).takeUnretainedValue()
    box.onOutput(Data(bytes: bytes, count: length))
}
private let iosAuthInputCallback: AuthInputCallback = { name, instructions, prompt, echo, responseBuffer, capacity, context in
    guard let name, let instructions, let prompt, let responseBuffer, let context, capacity >= 0 else { return -1 }
    let box = Unmanaged<IOSCallbacks>.fromOpaque(context).takeUnretainedValue()
    guard let response = box.onAuthInput(
        String(cString: name),
        String(cString: instructions),
        String(cString: prompt),
        echo
    ) else { return -1 }
    let bytes = Array(response.utf8)
    guard bytes.count <= capacity else { return -2 }
    for (index, byte) in bytes.enumerated() {
        responseBuffer[index] = CChar(bitPattern: byte)
    }
    return Int32(bytes.count)
}

final class Session: ObservableObject {
    private var pointer: OpaquePointer?
    private var context: UnsafeMutableRawPointer?
    init(pointer: OpaquePointer?, context: UnsafeMutableRawPointer? = nil) {
        self.pointer = pointer
        self.context = context
    }
    func write(_ bytes: [UInt8]) {
        guard let pointer else { return }
        bytes.withUnsafeBufferPointer { _ = c_session_write(pointer, $0.baseAddress, $0.count) }
    }
    func resize(cols: UInt32, rows: UInt32) { if let pointer { _ = c_session_resize(pointer, cols, rows) } }
    func close() {
        if let pointer { c_session_close(pointer); self.pointer = nil }
        if let context { Unmanaged<IOSCallbacks>.fromOpaque(context).release(); self.context = nil }
    }
    deinit { close() }
}

final class IOSConnectCancellation {
    private let lock = NSLock()
    private let userData: UnsafeMutableRawPointer
    private var active = true

    init(userData: UnsafeMutableRawPointer) { self.userData = userData }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if active { c_cancel_connect(userData) }
    }

    func finish() {
        lock.lock()
        c_finish_connect(userData)
        active = false
        lock.unlock()
    }
}

@main
struct HostShellIOSApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { HostListScreen().environmentObject(model) } }
}

struct HostListScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var activeSheet: HostListSheet?

    var body: some View {
        NavigationStack {
            List {
                Section("资产管理") {
                    Button { activeSheet = .keys } label: {
                        HStack {
                            Label("证书管理", systemImage: "key.fill")
                            Spacer()
                            Text("\(model.keys.count)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !model.jumps.isEmpty {
                    Section("跳板机资产 · \(model.jumps.count)") {
                        ForEach(model.jumps) { jump in
                            Label("\(jump.name)  ·  \(jump.hostname):\(jump.port)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.subheadline)
                        }
                    }
                }
                Section("主机 · \(model.hosts.count)") {
                    ForEach(model.hosts) { host in
                        HStack {
                            NavigationLink {
                                HostSessionScreen(host: host)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(host.name).font(.headline)
                                        Spacer()
                                        Text(host.proxy_mode.badgeName).font(.caption2).padding(4).background(.blue.opacity(0.12)).clipShape(Capsule())
                                        if let forwards = host.port_forwards, !forwards.isEmpty {
                                            Text("\(forwards.count) 隧道").font(.caption2).padding(4).background(.cyan.opacity(0.12)).clipShape(Capsule())
                                        }
                                    }
                                    Text("\(host.username)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button { activeSheet = .editHost(host) } label: {
                                Image(systemName: "pencil.circle").font(.title3)
                            }.buttonStyle(.borderless).accessibilityLabel("编辑 \(host.name)")
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.delete(host) } label: { Label("删除", systemImage: "trash") }
                            Button { activeSheet = .editHost(host) } label: { Label("编辑", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("HostShell")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { activeSheet = .jumps } label: { Image(systemName: "point.topleft.down.curvedto.point.bottomright.up") }
                        .accessibilityLabel("跳板机资产")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { activeSheet = .settings } label: { Image(systemName: "textformat") }.accessibilityLabel("终端设置")
                    Button { activeSheet = .keys } label: { Image(systemName: "key.fill") }.accessibilityLabel("证书管理")
                    Button { activeSheet = .importConfig } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入 SSH 配置")
                    Button { activeSheet = .newHost } label: { Image(systemName: "plus") }.accessibilityLabel("添加主机")
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .newHost: HostEditor(host: Host(), isNew: true, onSave: model.save)
                case .editHost(let host): HostEditor(host: host, onSave: model.save)
                case .importConfig: ImportSheet()
                case .jumps: JumpHostListSheet()
                case .keys: KeyManagementSheet()
                case .settings: IOSTerminalSettingsSheet()
                }
            }
            .alert("HostShell", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private enum HostListSheet: Identifiable {
    case newHost, editHost(Host), importConfig, jumps, keys, settings
    var id: String {
        switch self {
        case .newHost: return "new-host"
        case .editHost(let host): return "edit-\(host.id)"
        case .importConfig: return "import-config"
        case .jumps: return "jumps"
        case .keys: return "keys"
        case .settings: return "settings"
        }
    }
}

struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State var host: Host
    var isNew = false
    let onSave: (Host) -> Bool
    @State private var password = ""
    @State private var keyData = ""
    @State private var passphrase = ""
    @State private var useKey = false
    @State private var useSavedKey = false
    @State private var useAgent = false
    @State private var selectedKeyId = ""
    @State private var tagText = ""
    @State private var selectedJumpID = ""
    @State private var forwardDirection = "local"
    @State private var forwardBind = "127.0.0.1:8080"
    @State private var forwardTarget = "127.0.0.1:80"
    @State private var editingForwardIndex: Int?
    @State private var forwardError: String?
    @State private var forwardAgent = false
    @State private var forwardKeyIds: [String] = []
    @State private var forwardCertificateIds: [String] = []
    @State private var originalJumpID = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("主机") {
                    TextField("名称", text: $host.name)
                    TextField("主机名或 IP", text: $host.hostname).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $host.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", value: $host.port, format: .number).keyboardType(.numberPad)
                }
                Section("认证") {
                    Picker("认证方式", selection: Binding(get: { authChoice }, set: { choice in
                        useAgent = choice == 3
                        useSavedKey = choice == 2
                        useKey = choice == 1
                    })) {
                        Text("密码").tag(0)
                        Text("私钥").tag(1)
                        Text("已保存证书").tag(2)
                        Text("Agent").tag(3)
                    }.pickerStyle(.segmented)
                    if authChoice == 2 {
                        Picker("证书", selection: $selectedKeyId) {
                            Text("选择证书").tag("")
                            ForEach(model.keys) { Text($0.name).tag($0.id) }
                        }
                        if model.keys.isEmpty {
                            Text("暂无已保存的证书，请先在证书管理中导入私钥。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if authChoice == 1 {
                        TextEditor(text: $keyData).frame(minHeight: 130).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .overlay(alignment: .topLeading) { if keyData.isEmpty { Text("粘贴 OpenSSH 私钥").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) } }
                        SecureField("私钥密码（可选）", text: $passphrase)
                    } else if authChoice == 0 {
                        SecureField("密码", text: $password)
                    }
                }
                Section("连接方式") {
                    Picker("代理模式", selection: $host.proxy_mode) {
                        ForEach(ProxyMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    if host.proxy_mode == .proxyJump {
                        Picker("跳板机", selection: $selectedJumpID) {
                            Text("选择跳板机").tag("")
                            ForEach(model.jumps) { Text("\($0.name) · \($0.hostname)").tag($0.id) }
                        }
                    }
                    if host.proxy_mode == .proxyCommand {
                        TextField("ProxyCommand（支持 %h / %p）", text: Binding(
                            get: { host.proxy_command ?? "" },
                            set: { host.proxy_command = $0.isEmpty ? nil : $0 }
                        ))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        Text("例如: cloudflared access ssh --hostname %h。命令在本地执行，SSH 流量经其 stdin/stdout 转发。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("标签（逗号分隔）", text: $tagText)
                }
                Section("SSH 隧道与 Socket 转发") {
                    if let forwards = host.port_forwards, !forwards.isEmpty {
                        ForEach(forwards.indices, id: \.self) { index in
                            HStack {
                                Text(forwards[index].displayName)
                                    .font(.system(.footnote, design: .monospaced))
                                Spacer()
                                Button("编辑") { editForward(at: index) }
                                Button(role: .destructive) {
                                    var updated = host.port_forwards ?? []
                                    updated.remove(at: index)
                                    host.port_forwards = updated
                                    if editingForwardIndex != nil { resetForwardForm() }
                                } label: { Image(systemName: "trash") }
                            }
                        }
                    } else {
                        Text("尚未配置转发规则。规则会在 SSH 会话建立后启动。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("转发类型", selection: $forwardDirection) {
                        Text("本地 TCP / Socket").tag("local")
                        Text("SOCKS5 动态转发").tag("dynamic")
                        Text("远程 TCP / Socket").tag("remote")
                    }
                    TextField(bindEndpointTitle, text: $forwardBind)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if forwardDirection != "dynamic" {
                        TextField(targetEndpointTitle, text: $forwardTarget)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Text("TCP 示例：127.0.0.1:18085；Unix socket 示例：/tmp/hostshell.sock。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let forwardError { Text(forwardError).font(.footnote).foregroundStyle(.red) }
                    HStack {
                        Button(editingForwardIndex == nil ? "添加转发规则" : "保存修改") { saveForward() }
                        if editingForwardIndex != nil { Button("取消编辑") { resetForwardForm() } }
                    }
                }
                Section("SSH Agent 转发") {
                    Toggle("转发应用内 SSH Agent", isOn: $forwardAgent)
                    if forwardAgent {
                        Text("选择允许转发的证书（可多选）")
                            .font(.subheadline)
                        if model.keys.isEmpty {
                            Text("暂无已保存证书。请先在证书管理中导入私钥，或选择下方主机私钥。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(model.keys) { item in
                            Toggle(item.name, isOn: certificateBinding(item.id))
                        }
                        ForEach(forwardCertificateIds.filter { id in !model.keys.contains(where: { $0.id == id }) }, id: \.self) { id in
                            Toggle("证书不可用：\(id)", isOn: certificateBinding(id))
                        }
                        Text("仅对可信主机启用，选择允许远端使用的私钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if (useKey && !useSavedKey) || forwardKeyIds.contains(host.id) {
                            Toggle("当前主机的私钥", isOn: keyBinding(host.id))
                        }
                        ForEach(model.hosts.filter { item in
                            guard item.id != host.id else { return false }
                            if case .privateKey = item.auth { return true }
                            return false
                        }) { item in
                            Toggle(item.name, isOn: keyBinding(item.id))
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加主机" : "编辑主机")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let validationError = validationError {
                            saveError = validationError
                            return
                        }
                        switch authChoice {
                        case 1: host.auth = .privateKey(keyData: keyData, passphrase: passphrase.isEmpty ? nil : passphrase)
                        case 2: host.auth = .keyRef(id: selectedKeyId)
                        case 3: host.auth = .agent
                        default: host.auth = .password(password)
                        }
                        host.forward_agent = forwardAgent
                        host.forward_agent_host_ids = forwardAgent ? forwardKeyIds : []
                        host.forward_agent_key_ids = forwardAgent ? forwardCertificateIds : []
                        if selectedJumpID != originalJumpID {
                            host.jump_host_ids = selectedJumpID.isEmpty ? [] : [selectedJumpID]
                        }
                        host.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        if onSave(host) { dismiss() }
                        else { saveError = model.error ?? "保存主机失败。"; model.error = nil }
                    }
                }
            }
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .onAppear {
            switch host.auth {
            case .password(let value): password = value
            case .privateKey(let value, let phrase): useKey = true; keyData = value; passphrase = phrase ?? ""
            case .keyRef(let id): useSavedKey = true; selectedKeyId = id
            case .agent: useAgent = true
            }
            selectedJumpID = host.jump_host_ids.first ?? ""
            originalJumpID = selectedJumpID
            tagText = host.tags.joined(separator: ", ")
            forwardAgent = host.forward_agent ?? false
            forwardKeyIds = host.forward_agent_host_ids ?? []
            forwardCertificateIds = host.forward_agent_key_ids ?? []
        }
    }

    private func keyBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { forwardKeyIds.contains(id) }, set: { selected in
            if selected {
                if !forwardKeyIds.contains(id) { forwardKeyIds.append(id) }
            } else { forwardKeyIds.removeAll { $0 == id } }
        })
    }

    private func certificateBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { forwardCertificateIds.contains(id) }, set: { selected in
            if selected {
                if !forwardCertificateIds.contains(id) { forwardCertificateIds.append(id) }
            } else { forwardCertificateIds.removeAll { $0 == id } }
        })
    }

    private var bindEndpointTitle: String {
        switch forwardDirection {
        case "remote": return "远端监听地址和端口，或远端 socket 路径"
        case "dynamic": return "本地 SOCKS5 监听地址和端口"
        default: return "本地监听地址和端口，或本地 socket 路径"
        }
    }

    private var targetEndpointTitle: String {
        forwardDirection == "remote"
            ? "本地目标 host:port 或本地 socket 路径"
            : "远端目标 host:port 或远端 socket 路径"
    }

    private func editForward(at index: Int) {
        guard let rule = host.port_forwards?[index] else { return }
        forwardDirection = rule.direction
        forwardBind = rule.bind.configValue
        forwardTarget = rule.target?.configValue ?? ""
        editingForwardIndex = index
        forwardError = nil
    }

    private func saveForward() {
        guard let rule = PortForwardRule.parse(direction: forwardDirection, bind: forwardBind, target: forwardTarget) else {
            forwardError = "端点格式无效。TCP 使用 host:port，Unix socket 使用路径；端口需为 1–65535。"
            return
        }
        var updated = host.port_forwards ?? []
        if let index = editingForwardIndex, updated.indices.contains(index) {
            updated[index] = rule
        } else {
            updated.append(rule)
        }
        host.port_forwards = updated
        resetForwardForm()
    }

    private func resetForwardForm() {
        editingForwardIndex = nil
        forwardDirection = "local"
        forwardBind = "127.0.0.1:8080"
        forwardTarget = "127.0.0.1:80"
        forwardError = nil
    }

    private var validationError: String? {
        if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入主机名称。" }
        if host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入主机地址。" }
        if host.proxy_mode == .proxyJump && selectedJumpID.isEmpty { return "请选择跳板机。" }
        if host.proxy_mode == .proxyCommand && (host.proxy_command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入代理命令。" }
        if authChoice == 2 && !model.keys.contains(where: { $0.id == selectedKeyId }) { return "请选择用于主机认证的已保存证书。" }
        if forwardAgent && forwardKeyIds.isEmpty && forwardCertificateIds.isEmpty { return "请在 SSH Agent 转发中勾选至少一个证书或主机私钥。" }
        if forwardAgent && forwardCertificateIds.contains(where: { id in !model.keys.contains(where: { $0.id == id }) }) { return "转发列表中有不可用的证书，请取消勾选后保存。" }
        if forwardAgent && forwardKeyIds.contains(host.id) && authChoice != 1 { return "当前主机未使用私钥，请取消勾选当前主机的私钥。" }
        return nil
    }

    private var authChoice: Int {
        useAgent ? 3 : (useSavedKey ? 2 : (useKey ? 1 : 0))
    }
}

struct KeyManagementSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false
    @State private var pendingDelete: SSHKeyMetadata?
    @State private var error: String?
    @State private var savedKeyName: String?

    private func referencingCounts(_ key: SSHKeyMetadata) -> (hosts: Int, jumps: Int, forwards: Int) {
        let hosts = model.hosts.filter { $0.auth == .keyRef(id: key.id) }.count
        let jumps = model.jumps.filter { $0.auth == .keyRef(id: key.id) }.count
        let forwards = model.hosts.filter { $0.forward_agent_key_ids?.contains(key.id) == true }.count
        return (hosts, jumps, forwards)
    }

    private func usageText(_ key: SSHKeyMetadata) -> String {
        let usage = referencingCounts(key)
        var parts: [String] = []
        if usage.hosts > 0 { parts.append("\(usage.hosts) 台主机") }
        if usage.jumps > 0 { parts.append("\(usage.jumps) 个跳板机") }
        if usage.forwards > 0 { parts.append("\(usage.forwards) 处 Agent 转发") }
        return parts.isEmpty ? "未被引用" : "被 " + parts.joined(separator: " · ") + " 引用"
    }

    private var deleteWarning: String {
        guard let key = pendingDelete else { return "" }
        let usage = referencingCounts(key)
        if usage.hosts + usage.jumps + usage.forwards > 0 {
            return usageText(key) + "，需先在主机设置中解除引用才能删除。"
        }
        return "私钥将从 Keychain 中移除，此操作不可撤销。"
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.keys.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "key").font(.system(size: 42)).foregroundStyle(.tertiary)
                        Text("暂无证书").font(.headline)
                        Text("导入 SSH 私钥后，可在主机认证和 Agent 转发中使用。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("导入私钥") { showingImport = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("已保存证书 · \(model.keys.count)") {
                            ForEach(model.keys) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.headline)
                                    Text("\(item.algorithm) · \(item.fingerprint)")
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(usageText(item)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { pendingDelete = item } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                        }
                        Section {
                            Button { showingImport = true } label: {
                                Label("导入新私钥", systemImage: "plus")
                            }
                        }
                    }
                }
            }
            .navigationTitle("证书管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImport = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("导入私钥")
                }
            }
            .sheet(isPresented: $showingImport, onDismiss: {
                if let savedKeyName {
                    error = "证书“\(savedKeyName)”已保存，可在主机认证中选择。"
                    self.savedKeyName = nil
                }
            }) { KeyImportSheet(onSaved: { savedKeyName = $0 }) }
            .confirmationDialog(
                "删除证书「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let key = pendingDelete { error = model.deleteKey(key.id) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(deleteWarning)
            }
            .alert("HostShell", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct KeyImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var error: String?
    let onSaved: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("导入 SSH 私钥") {
                    TextField("证书名称", text: $name)
                    TextEditor(text: $key).frame(minHeight: 140).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if key.isEmpty { Text("粘贴 OpenSSH 或 PEM 私钥").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) }
                        }
                    SecureField("私钥密码（可选）", text: $passphrase)
                    Text("私钥保存在 Keychain，可供主机认证和 Agent 转发使用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导入私钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else { error = "请输入证书名称。"; return }
                        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请粘贴 SSH 私钥内容。"; return }
                        if let saveError = model.addKey(name: trimmedName, key: key, passphrase: passphrase) {
                            error = saveError
                        } else {
                            onSaved(trimmedName)
                            dismiss()
                        }
                    }
                }
            }
            .alert("无法保存证书", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct JumpHostListSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var username = ""
    @State private var port: UInt16 = 22
    @State private var password = ""
    @State private var keyData = ""
    @State private var useAgent = false
    @State private var selectedKeyId = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("已配置跳板机") {
                    ForEach(model.jumps) { j in
                        VStack(alignment: .leading) { Text(j.name).font(.headline); Text("\(j.username)@\(j.hostname):\(j.port)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("新增跳板机") {
                    TextField("名称", text: $name)
                    TextField("主机名", text: $hostname).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", value: $port, format: .number).keyboardType(.numberPad)
                    Toggle("使用外部 ssh-agent（iOS 通常不可用）", isOn: $useAgent)
                    if !useAgent {
                        Picker("已保存证书", selection: $selectedKeyId) {
                            Text("不使用证书").tag("")
                            ForEach(model.keys) { Text($0.name).tag($0.id) }
                        }
                        if selectedKeyId.isEmpty {
                        SecureField("密码", text: $password)
                        TextField("私钥（可选，粘贴）", text: $keyData, axis: .vertical).lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    Button("保存跳板机") {
                        let auth: AuthMethod = useAgent ? .agent : (!selectedKeyId.isEmpty ? .keyRef(id: selectedKeyId) : (keyData.isEmpty ? .password(password) : .privateKey(keyData: keyData, passphrase: nil)))
                        model.save(JumpHost(name: name, hostname: hostname, port: port, username: username, auth: auth))
                        name = ""; hostname = ""; password = ""; keyData = ""
                    }.disabled(name.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
            .navigationTitle("跳板机资产")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: ImportResponse?
    @State private var errorMessage: String?
    @State private var showingFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("导入 SSH 配置") {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("从“文件”选择配置", systemImage: "doc.badge.arrow.up")
                    }
                    Text("从 iCloud Drive 或“我的 iPhone”选择 ~/.ssh/config 或 joyy 文件；也可直接粘贴配置文本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("解析并预览") { parse() }
                }
                if let errorMessage {
                    Section("导入问题") {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if let result {
                    Section("解析预览") {
                        LabeledContent("主机", value: "\(result.hosts.count)")
                        LabeledContent("跳板机资产", value: "\(result.jump_hosts?.count ?? 0)")
                        ForEach(result.hosts) { host in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(host.name).font(.headline)
                                Text("\(host.username)@\(host.hostname):\(host.port) · \(host.proxy_mode.badgeName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(host.port_forwards ?? []) { rule in
                                    Label(rule.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                            }
                        }
                        ForEach(result.warnings, id: \.self) { warning in
                            Text(warning).foregroundStyle(.orange)
                        }
                    }
                    Button("导入 \(result.hosts.count) 台主机和 \(result.jump_hosts?.count ?? 0) 个跳板机") {
                        for host in result.hosts { model.save(host) }
                        for jump in result.jump_hosts ?? [] { model.save(jump) }
                        dismiss()
                    }
                    .disabled(result.hosts.isEmpty)
                }
            }
            .navigationTitle("导入 SSH 配置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.plainText, .data],
                allowsMultipleSelection: false
            ) { selection in
                switch selection {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        text = try String(contentsOf: url, encoding: .utf8)
                        errorMessage = nil
                        parse()
                    } catch {
                        errorMessage = "读取文件失败：\(error.localizedDescription)"
                        result = nil
                    }
                case .failure(let error):
                    errorMessage = "选择文件失败：\(error.localizedDescription)"
                    result = nil
                }
            }
        }
    }

    private func parse() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = nil
            errorMessage = "没有配置内容。请选择 joyy/config 文件，或粘贴其文本内容。"
            return
        }
        guard let parsed = model.importConfig(text) else {
            result = nil
            errorMessage = "配置解析失败。请确认文件是 UTF-8 编码的 OpenSSH config。"
            return
        }
        result = parsed
        errorMessage = parsed.hosts.isEmpty
            ? "没有识别到可导入的 Host。请确认粘贴的是配置文件内容，而不是文件路径；Host * 通配规则会被跳过。"
            : nil
    }
}

struct IOSAuthPromptInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let instructions: String
    let prompt: String
    let echo: Bool
}

final class IOSAuthPromptWaiter {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var completed = false
    private var response: String?

    func complete(_ response: String?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        self.response = response
        completed = true
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> String? {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

struct HostSessionScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let host: Host
    @StateObject private var terminal = TerminalModel()
    @StateObject private var networkMonitor = NetworkStatusMonitor()
    @State private var stage = "正在连接…"
    @State private var stageDetails = "正在连接…"
    @State private var connected = false
    @State private var connecting = true
    @State private var connectionAttempt = 0
    @State private var connectionNotice: String?
    @State private var showingTerminalSettings = false
    @State private var showingStageDetails = false
    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.fontFamilyKey) private var terminalFontFamily = TerminalFontFamily.system.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue
    @AppStorage(TerminalPreferences.cursorStyleKey) private var terminalCursorStyle = TerminalCursorStyle.block.rawValue
    @AppStorage(TerminalPreferences.emulationKey) private var terminalEmulation = TerminalEmulation.xterm256color.rawValue
    @AppStorage(TerminalPreferences.scrollbackLinesKey) private var terminalScrollbackLines = TerminalPreferences.defaultScrollbackLines
    @AppStorage(TerminalPreferences.keepaliveSecondsKey) private var terminalKeepaliveSeconds = TerminalPreferences.defaultKeepaliveSeconds
    @AppStorage("terminal.accessoryShortcuts") private var accessoryShortcutIDs = TerminalShortcut.defaultIDs.joined(separator: ",")

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(connected ? .green : (connecting ? .orange : .red)).frame(width: 8, height: 8)
                Button { showingStageDetails = true } label: {
                    Text(connectionNotice ?? stage).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("查看和复制连接状态")
                Spacer()
                Button { showingTerminalSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .font(.caption)
                .accessibilityLabel("终端设置")
                if connected || connecting {
                    Button(connecting ? "取消" : "断开") {
                        terminal.cancelConnect()
                        terminal.cancelPendingAuthPrompt()
                        terminal.session?.close()
                        terminal.session = nil
                        connected = false
                        connecting = false
                        stage = "连接已断开"
                    }.font(.caption)
                } else {
                    Button("重连", action: reconnect).font(.caption)
                }
            }.padding(8)
            IOSSwiftTerm(
                session: terminal,
                preferences: terminalPreferences,
                onResize: { cols, rows in
                terminal.session?.resize(cols: UInt32(cols), rows: UInt32(rows))
            }).background(themeBackground)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(selectedShortcuts) { shortcut in
                        terminalKeyButton(shortcut.title, bytes: shortcut.bytes)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .background(.bar)
        }
        .navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingStageDetails) {
            NavigationStack {
                ScrollView {
                    Text(stageDetails).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding()
                }
                .navigationTitle("连接详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingStageDetails = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("复制") { UIPasteboard.general.string = stageDetails } }
                }
            }
        }
        .sheet(item: $terminal.authPromptInfo) { prompt in
            IOSAuthInputSheet(terminal: terminal, prompt: prompt)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingTerminalSettings) {
            IOSTerminalSettingsSheet()
        }
        .task(id: connectionAttempt) {
            let attemptID = connectionAttempt
            let preferences = terminalPreferences
            terminal.beginConnectionAttempt()
            connecting = true
            let newSession = await Task.detached(priority: .userInitiated) {
                model.connect(host, onStage: { json in
                    DispatchQueue.main.async {
                        guard connectionAttempt == attemptID else { return }
                        if let data = json.data(using: .utf8),
                           let event = try? JSONDecoder().decode(StageEvent.self, from: data) {
                            let details = event.stage.details ?? [:]
                            let message = details["message"]?.value as? String
                            let suggestion = details["suggestion"]?.value as? String
                            stage = [event.stage.status, message, suggestion].compactMap { $0 }.joined(separator: "\n")
                            stageDetails = stage + "\n\n" + json
                            connected = event.stage.status == "connected"
                            connecting = !["connected", "disconnected", "failed"].contains(event.stage.status)
                        } else {
                            stage = json
                            stageDetails = json
                            connecting = false
                        }
                    }
                }, onOutput: { data in
                    DispatchQueue.main.async {
                        guard connectionAttempt == attemptID else { return }
                        terminal.output?(data)
                    }
                }, onAuthInput: { name, instructions, prompt, echo in
                    let info = IOSAuthPromptInfo(
                        id: UUID(),
                        name: name,
                        instructions: instructions,
                        prompt: prompt,
                        echo: echo
                    )
                    let waiter = IOSAuthPromptWaiter()
                    DispatchQueue.main.async {
                        terminal.beginAuthPrompt(info, waiter: waiter)
                    }
                    let response = waiter.wait()
                    DispatchQueue.main.async {
                        terminal.endAuthPrompt(info.id)
                    }
                    return response
                }, onConnectStarted: { cancellation in
                    DispatchQueue.main.async {
                        guard connectionAttempt == attemptID else {
                            cancellation.cancel()
                            return
                        }
                        terminal.beginConnect(cancellation)
                    }
                }, terminalPreferences: preferences)
            }.value
            guard connectionAttempt == attemptID else {
                newSession.close()
                return
            }
            terminal.connectCancellation?.finish()
            terminal.connectCancellation = nil
            terminal.session = newSession
            terminal.input = { [weak newSession] bytes in newSession?.write(bytes) }
            if !connected { connecting = false }
        }
        .onChange(of: networkMonitor.isAvailable) { available in
            guard let available else { return }
            if !available {
                connectionNotice = "网络不可用，SSH 连接可能已中断"
            } else if !connected {
                connectionNotice = "网络已恢复，可点击重连"
            } else {
                connectionNotice = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                connectionNotice = "应用已进入后台，系统可能暂停网络连接"
            } else if phase == .active {
                connectionNotice = connected ? nil : "应用已回到前台，可点击重连"
            }
        }
        .onDisappear {
            terminal.cancelConnect()
            terminal.cancelPendingAuthPrompt()
            terminal.session?.close()
        }
    }

    private func reconnect() {
        terminal.cancelConnect()
        terminal.cancelPendingAuthPrompt()
        terminal.session?.close()
        terminal.session = nil
        terminal.beginConnectionAttempt()
        connected = false
        connecting = true
        connectionNotice = nil
        stage = "正在重连…"
        stageDetails = stage
        connectionAttempt += 1
    }

    private func terminalKeyButton(_ title: String, bytes: [UInt8]) -> some View {
        Button(title) { terminal.session?.write(bytes) }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
    }

    private var themeBackground: SwiftUI.Color {
        terminalPreferences.theme == .dark ? .black : .white
    }

    private var terminalPreferences: TerminalPreferences {
        TerminalPreferences(
            fontSize: terminalFontSize,
            fontFamily: TerminalFontFamily(rawValue: terminalFontFamily) ?? .system,
            theme: TerminalTheme(rawValue: terminalTheme) ?? .dark,
            cursorStyle: TerminalCursorStyle(rawValue: terminalCursorStyle) ?? .block,
            emulation: TerminalEmulation(rawValue: terminalEmulation) ?? .xterm256color,
            scrollbackLines: terminalScrollbackLines,
            keepaliveSeconds: terminalKeepaliveSeconds
        )
    }

    private var selectedShortcuts: [TerminalShortcut] {
        let selected = Set(accessoryShortcutIDs.split(separator: ",").map(String.init))
        return TerminalShortcut.allCases.filter { selected.contains($0.id) }
    }
}

private struct IOSTerminalSettingsSheet: View {
    @AppStorage(TerminalPreferences.fontSizeKey) private var terminalFontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.fontFamilyKey) private var terminalFontFamily = TerminalFontFamily.system.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalTheme.dark.rawValue
    @AppStorage(TerminalPreferences.cursorStyleKey) private var terminalCursorStyle = TerminalCursorStyle.block.rawValue
    @AppStorage(TerminalPreferences.emulationKey) private var terminalEmulation = TerminalEmulation.xterm256color.rawValue
    @AppStorage(TerminalPreferences.scrollbackLinesKey) private var terminalScrollbackLines = TerminalPreferences.defaultScrollbackLines
    @AppStorage(TerminalPreferences.keepaliveSecondsKey) private var terminalKeepaliveSeconds = TerminalPreferences.defaultKeepaliveSeconds
    @AppStorage("terminal.accessoryShortcuts") private var accessoryShortcutIDs = TerminalShortcut.defaultIDs.joined(separator: ",")

    var body: some View {
        NavigationStack {
            Form {
                Section("终端外观") {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Text("\(Int(terminalFontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $terminalFontSize, in: 10...24, step: 1)
                        .accessibilityLabel("终端字体大小")
                    Picker("等宽字体", selection: $terminalFontFamily) {
                        ForEach(TerminalFontFamily.allCases) { font in
                            Text(font.displayName).tag(font.rawValue)
                        }
                    }
                    Picker("配色主题", selection: $terminalTheme) {
                        ForEach(TerminalTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("光标样式", selection: $terminalCursorStyle) {
                        ForEach(TerminalCursorStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                }

                Section("会话参数") {
                    Picker("终端仿真", selection: $terminalEmulation) {
                        ForEach(TerminalEmulation.allCases) { type in
                            Text(type.rawValue).tag(type.rawValue)
                        }
                    }
                    Stepper(value: $terminalScrollbackLines, in: 100...10_000, step: 100) {
                        HStack {
                            Text("滚动缓冲区")
                            Spacer()
                            Text("\(terminalScrollbackLines) 行").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Stepper(value: $terminalKeepaliveSeconds, in: 0...120, step: 5) {
                        HStack {
                            Text("SSH 心跳")
                            Spacer()
                            Text(terminalKeepaliveSeconds == 0 ? "关闭" : "\(terminalKeepaliveSeconds) 秒")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Text("心跳范围：关闭或 5–120 秒。滚动缓冲区范围：100–10,000 行。终端仿真和心跳在下次连接时生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("快捷键栏") {
                    Text("选择要显示在终端下方的按键。按键会立即生效并保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(TerminalShortcut.allCases) { shortcut in
                        Toggle(shortcut.title, isOn: shortcutBinding(for: shortcut))
                    }
                }
            }
            .navigationTitle("终端设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func shortcutBinding(for shortcut: TerminalShortcut) -> Binding<Bool> {
        Binding(
            get: { selectedShortcutIDs.contains(shortcut.id) },
            set: { isEnabled in
                var selected = selectedShortcutIDs
                if isEnabled {
                    selected.insert(shortcut.id)
                } else {
                    selected.remove(shortcut.id)
                }
                accessoryShortcutIDs = TerminalShortcut.allCases
                    .filter { selected.contains($0.id) }
                    .map(\.id)
                    .joined(separator: ",")
            }
        )
    }

    private var selectedShortcutIDs: Set<String> {
        Set(accessoryShortcutIDs.split(separator: ",").map(String.init))
    }
}

private enum TerminalShortcut: String, CaseIterable, Identifiable {
    case escape, tab, controlC, controlD, controlA, controlE, controlL, controlZ
    case altB, altF, altLeft, altRight
    case left, up, down, right

    static let defaultIDs = ["escape", "tab", "controlC", "controlD", "up", "down"]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .controlC: return "Ctrl-C"
        case .controlD: return "Ctrl-D"
        case .controlA: return "Ctrl-A"
        case .controlE: return "Ctrl-E"
        case .controlL: return "Ctrl-L"
        case .controlZ: return "Ctrl-Z"
        case .altB: return "Alt-B"
        case .altF: return "Alt-F"
        case .altLeft: return "Alt-←"
        case .altRight: return "Alt-→"
        case .left: return "←"
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .escape: return [0x1B]
        case .tab: return [0x09]
        case .controlC: return [0x03]
        case .controlD: return [0x04]
        case .controlA: return [0x01]
        case .controlE: return [0x05]
        case .controlL: return [0x0C]
        case .controlZ: return [0x1A]
        case .altB: return [0x1B, 0x62]
        case .altF: return [0x1B, 0x66]
        case .altLeft: return [0x1B, 0x1B, 0x5B, 0x44]
        case .altRight: return [0x1B, 0x1B, 0x5B, 0x43]
        case .left: return [0x1B, 0x5B, 0x44]
        case .up: return [0x1B, 0x5B, 0x41]
        case .down: return [0x1B, 0x5B, 0x42]
        case .right: return [0x1B, 0x5B, 0x43]
        }
    }
}

@MainActor
final class TerminalModel: ObservableObject {
    var session: Session?
    var connectCancellation: IOSConnectCancellation?
    private var connectionCancelled = false
    var output: ((Data) -> Void)?
    var input: (([UInt8]) -> Void)?
    @Published var authPromptInfo: IOSAuthPromptInfo?
    private var authPromptWaiter: IOSAuthPromptWaiter?

    func beginConnect(_ cancellation: IOSConnectCancellation) {
        if connectionCancelled {
            cancellation.cancel()
        } else {
            connectCancellation = cancellation
        }
    }

    func beginConnectionAttempt() {
        connectionCancelled = false
        connectCancellation = nil
    }

    func cancelConnect() {
        connectionCancelled = true
        connectCancellation?.cancel()
        connectCancellation = nil
    }

    func beginAuthPrompt(_ info: IOSAuthPromptInfo, waiter: IOSAuthPromptWaiter) {
        authPromptInfo = info
        authPromptWaiter = waiter
    }

    func endAuthPrompt(_ id: UUID) {
        if authPromptInfo?.id == id { authPromptInfo = nil }
        if authPromptInfo == nil { authPromptWaiter = nil }
    }

    func submitAuthInput(_ response: String, for id: UUID) {
        guard authPromptInfo?.id == id else { return }
        authPromptWaiter?.complete(response)
    }

    func cancelAuthInput(for id: UUID) {
        guard authPromptInfo?.id == id else { return }
        authPromptWaiter?.complete(nil)
    }

    func cancelPendingAuthPrompt() {
        authPromptWaiter?.complete(nil)
        authPromptWaiter = nil
        authPromptInfo = nil
    }
}

@MainActor
final class NetworkStatusMonitor: ObservableObject {
    @Published private(set) var isAvailable: Bool?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.hostshell.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isAvailable = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

private struct IOSAuthInputSheet: View {
    @ObservedObject var terminal: TerminalModel
    let prompt: IOSAuthPromptInfo
    @State private var response = ""
    @FocusState private var responseFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !prompt.name.isEmpty { Text(prompt.name) }
                    if !prompt.instructions.isEmpty { Text(prompt.instructions).font(.footnote) }
                }
                Section {
                    if prompt.echo {
                        TextField(prompt.prompt, text: $response).focused($responseFocused)
                    } else {
                        SecureField(prompt.prompt, text: $response).focused($responseFocused)
                    }
                }
            }
            .navigationTitle("SSH authentication challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { terminal.cancelAuthInput(for: prompt.id) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") {
                        terminal.submitAuthInput(response, for: prompt.id)
                        response = ""
                    }
                }
            }
            .onAppear { responseFocused = true }
        }
    }
}

struct IOSSwiftTerm: UIViewRepresentable {
    @ObservedObject var session: TerminalModel
    let preferences: TerminalPreferences
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let options = SwiftTerm.TerminalOptions(
            termName: preferences.emulation.rawValue,
            cursorStyle: swiftCursorStyle,
            scrollback: preferences.scrollbackLines
        )
        let view = SwiftTerm.TerminalView(
            frame: .zero,
            font: terminalFont,
            options: options
        )
        view.terminalDelegate = context.coordinator
        applyAppearance(to: view)
        session.output = { [weak view] data in view?.feed(byteArray: Array(data)[...]) }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        applyAppearance(to: uiView)
    }

    private func applyAppearance(to view: SwiftTerm.TerminalView) {
        if view.font != terminalFont {
            view.font = terminalFont
        }
        let terminal = view.getTerminal()
        terminal.setCursorStyle(swiftCursorStyle)
        if terminal.options.scrollback != preferences.scrollbackLines {
            terminal.changeHistorySize(preferences.scrollbackLines)
        }
        switch preferences.theme {
        case .dark:
            view.nativeBackgroundColor = .black
            view.nativeForegroundColor = .white
        case .light:
            view.nativeBackgroundColor = .white
            view.nativeForegroundColor = .black
        }
    }

    private var terminalFont: UIFont {
        let size = CGFloat(min(max(preferences.fontSize, 10), 24))
        if let name = preferences.fontFamily.postScriptName,
           let font = UIFont(name: name, size: size) {
            return font
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var swiftCursorStyle: SwiftTerm.CursorStyle {
        switch preferences.cursorStyle {
        case .block: return .blinkBlock
        case .underline: return .steadyUnderline
        case .bar: return .steadyBar
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session, onResize: onResize) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalModel
        let onResize: (Int, Int) -> Void
        init(session: TerminalModel, onResize: @escaping (Int, Int) -> Void) {
            self.session = session
            self.onResize = onResize
        }
        @MainActor
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session.input?(Array(data))
        }

        @MainActor
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) { AudioServicesPlaySystemSound(1104) }
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
