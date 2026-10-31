import SwiftUI
import Combine
import Foundation
import SwiftTerm
import UIKit
import AudioToolbox
import UniformTypeIdentifiers

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
@_silgen_name("hostshell_connect") private func c_connect(_ engine: OpaquePointer?, _ host: UnsafePointer<CChar>?, _ cols: UInt32, _ rows: UInt32, _ autoAccept: Bool, _ stage: StageCallback?, _ output: OutputCallback?, _ ctx: UnsafeMutableRawPointer?) -> OpaquePointer?
@_silgen_name("hostshell_session_write") private func c_session_write(_ session: OpaquePointer?, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Int32
@_silgen_name("hostshell_session_resize") private func c_session_resize(_ session: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Int32
@_silgen_name("hostshell_session_close") private func c_session_close(_ session: OpaquePointer?)

private typealias StageCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias OutputCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void

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

    func save(_ host: Host) {
        guard let data = try? JSONEncoder().encode(host), let json = String(data: data, encoding: .utf8) else { return }
        let rc = json.withCString { c_save_host(engine, $0) }
        if rc != 0 { error = "保存主机失败（错误码 \(rc)）" }
        reload()
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

    func connect(_ host: Host, onStage: @escaping (String) -> Void, onOutput: @escaping (Data) -> Void) -> Session {
        let context = IOSCallbacks(onStage: onStage, onOutput: onOutput)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        guard let data = try? JSONEncoder().encode(host), let json = String(data: data, encoding: .utf8) else {
            Unmanaged<IOSCallbacks>.fromOpaque(opaque).release()
            return Session(pointer: nil)
        }
        let pointer = json.withCString { c_connect(engine, $0, 80, 24, true, iosStageCallback, iosOutputCallback, opaque) }
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
    init(onStage: @escaping (String) -> Void, onOutput: @escaping (Data) -> Void) {
        self.onStage = onStage
        self.onOutput = onOutput
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

@main
struct HostShellIOSApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { HostListScreen().environmentObject(model) } }
}

struct HostListScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var editorHost: Host?
    @State private var editingNew = false
    @State private var showingImport = false
    @State private var showingJumps = false
    @State private var showingKeys = false

    var body: some View {
        NavigationStack {
            List {
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
                        NavigationLink {
                            HostSessionScreen(host: host)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(host.name).font(.headline)
                                    Spacer()
                                    Text(host.proxy_mode.badgeName).font(.caption2).padding(4).background(.blue.opacity(0.12)).clipShape(Capsule())
                                }
                                Text("\(host.username)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.delete(host) } label: { Label("删除", systemImage: "trash") }
                            Button { editorHost = host } label: { Label("编辑", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("HostShell")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingJumps = true } label: { Image(systemName: "point.topleft.down.curvedto.point.bottomright.up") }
                        .accessibilityLabel("跳板机资产")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingKeys = true } label: { Image(systemName: "key.fill") }.accessibilityLabel("证书管理")
                    Button { showingImport = true } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入 SSH 配置")
                    Button { editingNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加主机")
                }
            }
            .sheet(isPresented: $editingNew) { HostEditor(host: Host(), onSave: model.save) }
            .sheet(item: $editorHost) { HostEditor(host: $0, onSave: model.save) }
            .sheet(isPresented: $showingImport) { ImportSheet() }
            .sheet(isPresented: $showingJumps) { JumpHostListSheet() }
            .sheet(isPresented: $showingKeys) { KeyManagementSheet() }
            .alert("HostShell", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State var host: Host
    let onSave: (Host) -> Void
    @State private var password = ""
    @State private var keyData = ""
    @State private var passphrase = ""
    @State private var useKey = false
    @State private var useSavedKey = false
    @State private var selectedKeyId = ""
    @State private var tagText = ""
    @State private var selectedJumpID = ""
    @State private var forwardAgent = false
    @State private var forwardKeyIds: [String] = []
    @State private var forwardCertificateId = ""

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
                    Toggle("使用已保存证书", isOn: $useSavedKey)
                    if useSavedKey {
                        Picker("证书", selection: $selectedKeyId) {
                            Text("选择证书").tag("")
                            ForEach(model.keys) { Text($0.name).tag($0.id) }
                        }
                    } else {
                    Picker("认证方式", selection: $useKey) { Text("密码").tag(false); Text("私钥").tag(true) }.pickerStyle(.segmented)
                    if useKey {
                        TextEditor(text: $keyData).frame(minHeight: 130).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .overlay(alignment: .topLeading) { if keyData.isEmpty { Text("粘贴 OpenSSH 私钥").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) } }
                        SecureField("私钥密码（可选）", text: $passphrase)
                    } else {
                        SecureField("密码", text: $password)
                    }
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
                Section("SSH Agent 转发") {
                    Toggle("转发应用内 SSH Agent", isOn: $forwardAgent)
                    if forwardAgent {
                        Picker("转发证书", selection: $forwardCertificateId) {
                            Text("选择证书").tag("")
                            ForEach(model.keys) { Text($0.name).tag($0.id) }
                        }
                        Text("仅对可信主机启用，选择允许远端使用的私钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if useKey && !useSavedKey { Toggle("当前主机的私钥", isOn: keyBinding(host.id)) }
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
            .navigationTitle("添加主机")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        host.auth = useSavedKey ? .keyRef(id: selectedKeyId) : (useKey ? .privateKey(keyData: keyData, passphrase: passphrase.isEmpty ? nil : passphrase) : .password(password))
                        host.forward_agent = forwardAgent
                        host.forward_agent_host_ids = forwardAgent ? forwardKeyIds : []
                        host.forward_agent_key_ids = forwardAgent && !forwardCertificateId.isEmpty ? [forwardCertificateId] : []
                        host.jump_host_ids = selectedJumpID.isEmpty ? [] : [selectedJumpID]
                        host.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        onSave(host)
                        dismiss()
                    }.disabled(host.name.isEmpty || host.hostname.isEmpty || (host.proxy_mode == .proxyJump && selectedJumpID.isEmpty) || (host.proxy_mode == .proxyCommand && (host.proxy_command ?? "").trimmingCharacters(in: .whitespaces).isEmpty) || (useSavedKey && !model.keys.contains(where: { $0.id == selectedKeyId })) || (forwardAgent && forwardKeyIds.isEmpty && forwardCertificateId.isEmpty) || (forwardAgent && forwardKeyIds.contains(host.id) && (useSavedKey || !useKey)))
                }
            }
        }
        .onAppear {
            switch host.auth {
            case .password(let value): password = value
            case .privateKey(let value, let phrase): useKey = true; keyData = value; passphrase = phrase ?? ""
            case .keyRef(let id): useSavedKey = true; selectedKeyId = id
            case .agent: break
            }
            selectedJumpID = host.jump_host_ids.first ?? ""
            tagText = host.tags.joined(separator: ", ")
            forwardAgent = host.forward_agent ?? false
            forwardKeyIds = host.forward_agent_host_ids ?? []
            forwardCertificateId = host.forward_agent_key_ids?.first ?? ""
        }
    }

    private func keyBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { forwardKeyIds.contains(id) }, set: { selected in
            if selected {
                if !forwardKeyIds.contains(id) { forwardKeyIds.append(id) }
            } else { forwardKeyIds.removeAll { $0 == id } }
        })
    }
}

struct KeyManagementSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("已保存证书") {
                    ForEach(model.keys) { item in
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text("\(item.algorithm) · \(item.fingerprint)").font(.caption).textSelection(.enabled)
                            Button("删除", role: .destructive) { error = model.deleteKey(item.id) }
                        }
                    }
                }
                Section("导入 SSH 私钥") {
                    TextField("证书名称", text: $name)
                    TextEditor(text: $key).frame(minHeight: 140).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("私钥密码（可选）", text: $passphrase)
                    Text("私钥保存在 Keychain，可供主机认证和 Agent 转发使用。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("保存证书") {
                        error = model.addKey(name: name, key: key, passphrase: passphrase)
                        if error == nil { name = ""; key = ""; passphrase = "" }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || key.isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("证书管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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

struct HostSessionScreen: View {
    @EnvironmentObject private var model: AppModel
    let host: Host
    @StateObject private var terminal = TerminalModel()
    @State private var stage = "正在连接…"
    @State private var connected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(connected ? .green : .orange).frame(width: 8, height: 8)
                Text(stage).font(.caption).lineLimit(1)
                Spacer()
                Button("断开") { terminal.session?.close(); connected = false }.font(.caption)
            }.padding(8)
            IOSSwiftTerm(session: terminal, onResize: { cols, rows in
                terminal.session?.resize(cols: UInt32(cols), rows: UInt32(rows))
            }).background(Color.black)
            HStack(spacing: 18) {
                terminalKeyButton("ESC", bytes: [0x1B])
                terminalKeyButton("TAB", bytes: [0x09])
                terminalKeyButton("CTRL-C", bytes: [0x03])
                terminalKeyButton("CTRL-D", bytes: [0x04])
                terminalKeyButton("↑", bytes: [0x1B, 0x5B, 0x41])
                terminalKeyButton("↓", bytes: [0x1B, 0x5B, 0x42])
            }.padding(9).background(.bar)
        }
        .navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
        .task {
            let newSession = await Task.detached(priority: .userInitiated) {
                model.connect(host, onStage: { json in
                    DispatchQueue.main.async {
                        stage = json
                        if json.contains("connected") { connected = true }
                    }
                }, onOutput: { data in
                    DispatchQueue.main.async { terminal.output?(data) }
                })
            }.value
            terminal.session = newSession
            terminal.input = { [weak newSession] bytes in newSession?.write(bytes) }
        }
        .onDisappear { terminal.session?.close() }
    }

    private func terminalKeyButton(_ title: String, bytes: [UInt8]) -> some View {
        Button(title) { terminal.session?.write(bytes) }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
    }
}

@MainActor
final class TerminalModel: ObservableObject {
    var session: Session?
    var output: ((Data) -> Void)?
    var input: (([UInt8]) -> Void)?
}

struct IOSSwiftTerm: UIViewRepresentable {
    @ObservedObject var session: TerminalModel
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .black
        session.output = { [weak view] data in view?.feed(byteArray: Array(data)[...]) }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

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
