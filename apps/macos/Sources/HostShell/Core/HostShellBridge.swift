import Foundation
import AppKit

@_silgen_name("hostshell_list_keys")
func c_hostshell_list_keys(_ engine: OpaquePointer?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_add_key")
func c_hostshell_add_key(_ engine: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("hostshell_delete_key")
func c_hostshell_delete_key(_ engine: OpaquePointer?, _ id: UnsafePointer<CChar>?) -> Int32

// C-ABI declarations matching crates/hostshell-core/src/ffi/mod.rs
@_silgen_name("hostshell_engine_init")
func c_hostshell_engine_init() -> OpaquePointer?

@_silgen_name("hostshell_engine_free")
func c_hostshell_engine_free(_ engine: OpaquePointer?)

@_silgen_name("hostshell_free_string")
func c_hostshell_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("hostshell_log_directory")
func c_hostshell_log_directory() -> UnsafeMutablePointer<CChar>?

@_silgen_name("hostshell_list_hosts")
func c_hostshell_list_hosts(_ engine: OpaquePointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("hostshell_save_host")
func c_hostshell_save_host(_ engine: OpaquePointer?, _ hostJson: UnsafePointer<CChar>?) -> Int32

@_silgen_name("hostshell_delete_host")
func c_hostshell_delete_host(_ engine: OpaquePointer?, _ hostId: UnsafePointer<CChar>?) -> Int32

@_silgen_name("hostshell_list_jump_hosts")
func c_hostshell_list_jump_hosts(_ engine: OpaquePointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("hostshell_save_jump_host")
func c_hostshell_save_jump_host(_ engine: OpaquePointer?, _ jhJson: UnsafePointer<CChar>?) -> Int32

@_silgen_name("hostshell_delete_jump_host")
func c_hostshell_delete_jump_host(_ engine: OpaquePointer?, _ jhId: UnsafePointer<CChar>?) -> Int32

@_silgen_name("hostshell_import_ssh_config")
func c_hostshell_import_ssh_config(_ engine: OpaquePointer?, _ configText: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

typealias StageCallbackC = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias OutputCallbackC = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void

@_silgen_name("hostshell_connect")
func c_hostshell_connect(
    _ engine: OpaquePointer?,
    _ hostJson: UnsafePointer<CChar>?,
    _ cols: UInt32,
    _ rows: UInt32,
    _ autoAcceptNewKeys: Bool,
    _ stageCb: StageCallbackC?,
    _ outputCb: OutputCallbackC?,
    _ userData: UnsafeMutableRawPointer?
) -> OpaquePointer?

@_silgen_name("hostshell_session_write")
func c_hostshell_session_write(_ session: OpaquePointer?, _ data: UnsafePointer<UInt8>?, _ len: Int) -> Int32

@_silgen_name("hostshell_session_resize")
func c_hostshell_session_resize(_ session: OpaquePointer?, _ cols: UInt32, _ rows: UInt32) -> Int32

@_silgen_name("hostshell_session_close")
func c_hostshell_session_close(_ session: OpaquePointer?)

public final class SessionHandleBridge {
    private var sessionPtr: OpaquePointer?
    private let onStage: (String) -> Void
    private let onOutput: (Data) -> Void

    fileprivate init(
        sessionPtr: OpaquePointer,
        onStage: @escaping (String) -> Void,
        onOutput: @escaping (Data) -> Void
    ) {
        self.sessionPtr = sessionPtr
        self.onStage = onStage
        self.onOutput = onOutput
    }

    deinit {
        close()
    }

    public func write(_ data: Data) {
        guard let ptr = sessionPtr else { return }
        data.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                _ = c_hostshell_session_write(ptr, base, data.count)
            }
        }
    }

    public func resize(cols: UInt32, rows: UInt32) {
        guard let ptr = sessionPtr else { return }
        _ = c_hostshell_session_resize(ptr, cols, rows)
    }

    public func close() {
        if let ptr = sessionPtr {
            sessionPtr = nil
            c_hostshell_session_close(ptr)
        }
    }

    fileprivate func handleStageEvent(json: String) {
        onStage(json)
    }

    fileprivate func handleOutput(data: Data) {
        onOutput(data)
    }
}

public final class HostShellBridge: @unchecked Sendable {
    public static let shared = HostShellBridge()
    private var enginePtr: OpaquePointer?

    private init() {
        enginePtr = c_hostshell_engine_init()
        if enginePtr == nil {
            NSLog("[HostShellBridge] Critical: Failed to initialize Rust hostshell core engine!")
        }
    }

    public func listKeys() -> [SSHKeyMetadata] {
        guard let ptr = c_hostshell_list_keys(enginePtr) else { return [] }
        defer { c_hostshell_free_string(ptr) }
        return (try? JSONDecoder().decode([SSHKeyMetadata].self, from: Data(String(cString: ptr).utf8))) ?? []
    }

    public func addKey(name: String, key: String, passphrase: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["name": name, "key_data": key, "passphrase": passphrase]),
              let json = String(data: data, encoding: .utf8),
              let ptr = json.withCString({ c_hostshell_add_key(enginePtr, $0) }) else { return "保存失败" }
        defer { c_hostshell_free_string(ptr) }
        guard let response = try? JSONSerialization.jsonObject(with: Data(String(cString: ptr).utf8)) as? [String: Any] else { return "保存失败" }
        return response["ok"] as? Bool == true ? nil : (response["error"] as? String ?? "保存失败")
    }

    public func deleteKey(_ id: String) -> Int32 { id.withCString { c_hostshell_delete_key(enginePtr, $0) } }

    deinit {
        if let ptr = enginePtr {
            c_hostshell_engine_free(ptr)
        }
    }

    public func listHosts() -> [Host] {
        guard let ptr = enginePtr, let cStr = c_hostshell_list_hosts(ptr) else { return [] }
        defer { c_hostshell_free_string(cStr) }
        let jsonStr = String(cString: cStr)
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Host].self, from: data)) ?? []
    }

    public func saveHost(_ host: Host) -> Bool {
        guard let ptr = enginePtr else { return false }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(host),
              let jsonStr = String(data: data, encoding: .utf8) else { return false }
        return c_hostshell_save_host(ptr, jsonStr) == 0
    }

    public func deleteHost(id: String) -> Bool {
        guard let ptr = enginePtr else { return false }
        return c_hostshell_delete_host(ptr, id) == 0
    }

    public func listJumpHosts() -> [JumpHost] {
        guard let ptr = enginePtr, let cStr = c_hostshell_list_jump_hosts(ptr) else { return [] }
        defer { c_hostshell_free_string(cStr) }
        let jsonStr = String(cString: cStr)
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([JumpHost].self, from: data)) ?? []
    }

    public func saveJumpHost(_ jh: JumpHost) -> Bool {
        guard let ptr = enginePtr else { return false }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(jh),
              let jsonStr = String(data: data, encoding: .utf8) else { return false }
        return c_hostshell_save_jump_host(ptr, jsonStr) == 0
    }

    public func deleteJumpHost(id: String) -> Bool {
        guard let ptr = enginePtr else { return false }
        return c_hostshell_delete_jump_host(ptr, id) == 0
    }

    public func openLogDirectory() {
        guard let ptr = c_hostshell_log_directory() else { return }
        defer { c_hostshell_free_string(ptr) }
        let path = String(cString: ptr)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func importSshConfig(text: String) -> SshConfigImportResponse? {
        guard let ptr = enginePtr, let cStr = c_hostshell_import_ssh_config(ptr, text) else { return nil }
        defer { c_hostshell_free_string(cStr) }
        let jsonStr = String(cString: cStr)
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(SshConfigImportResponse.self, from: data)
        } catch {
            NSLog("[HostShellBridge] SSH config import response decode failed: %@", String(describing: error))
            return nil
        }
    }

    public func connect(
        host: Host,
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        autoAcceptNewKeys: Bool = true,
        onStage: @escaping (String) -> Void,
        onOutput: @escaping (Data) -> Void
    ) -> SessionHandleBridge? {
        guard let ptr = enginePtr else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(host),
              let jsonStr = String(data: data, encoding: .utf8) else { return nil }

        // Context box passed to C callbacks
        final class CallbackContext {
            let onStage: (String) -> Void
            let onOutput: (Data) -> Void

            init(onStage: @escaping (String) -> Void, onOutput: @escaping (Data) -> Void) {
                self.onStage = onStage
                self.onOutput = onOutput
            }
        }
        let ctx = CallbackContext(onStage: onStage, onOutput: onOutput)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        let stageCb: StageCallbackC = { cJson, userPtr in
            guard let cJson = cJson, let userPtr = userPtr else { return }
            let jsonString = String(cString: cJson)
            let box = Unmanaged<CallbackContext>.fromOpaque(userPtr).takeUnretainedValue()
            box.onStage(jsonString)
        }

        let outputCb: OutputCallbackC = { cBytes, len, userPtr in
            guard let cBytes = cBytes, len > 0, let userPtr = userPtr else { return }
            let dataChunk = Data(bytes: cBytes, count: len)
            let box = Unmanaged<CallbackContext>.fromOpaque(userPtr).takeUnretainedValue()
            box.onOutput(dataChunk)
        }

        let sessPtr = c_hostshell_connect(
            ptr,
            jsonStr,
            cols,
            rows,
            autoAcceptNewKeys,
            stageCb,
            outputCb,
            ctxPtr
        )

        guard let validSess = sessPtr else {
            _ = Unmanaged<CallbackContext>.fromOpaque(ctxPtr).takeRetainedValue()
            return nil
        }

        let sessionBridge = SessionHandleBridge(sessionPtr: validSess, onStage: onStage, onOutput: onOutput)
        return sessionBridge
    }
}
