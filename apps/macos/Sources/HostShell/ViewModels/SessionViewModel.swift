import SwiftUI
import Combine

public struct StageItem: Identifiable, Equatable {
    public let id = UUID()
    public let status: String
    public let description: String
    public let isSuccess: Bool
    public let isFailed: Bool
    public let isCurrent: Bool
}

public struct FailureInfo: Equatable {
    public let stage: String
    public let category: String
    public let message: String
    public let suggestion: String
}

public struct HostKeyPromptInfo: Equatable {
    public let host: String
    public let keyType: String
    public let fingerprint: String
}

public struct AuthPromptInfo: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let instructions: String
    public let prompt: String
    public let echo: Bool
}

private final class AuthPromptWaiter {
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

@MainActor
public final class SessionViewModel: ObservableObject {
    public let host: Host
    private let bridge = HostShellBridge.shared
    private var sessionBridge: SessionHandleBridge?
    private var connectionID = UUID()
    private var terminalSize: (cols: UInt32, rows: UInt32)?
    private var connectCancellation: ConnectCancellationBridge?

    @Published public var isConnecting: Bool = false
    @Published public var isConnected: Bool = false
    @Published public var isDisconnected: Bool = false
    @Published public var disconnectReason: String = ""

    @Published public var stages: [StageItem] = []
    @Published public var failureInfo: FailureInfo? = nil
    @Published public var hostKeyPrompt: HostKeyPromptInfo? = nil
    @Published public var authPromptInfo: AuthPromptInfo? = nil
    private var authPromptWaiter: AuthPromptWaiter?

    /// Raw byte chunks pending for the terminal emulator (SwiftTerm drains this).
    private var pendingOutput = Data()
    /// Bumped on every output chunk so SwiftUI re-renders and drains the buffer.
    @Published public var outputRevision: Int = 0

    /// Drain accumulated raw output bytes for the terminal emulator.
    public func takePendingOutput() -> Data? {
        guard !pendingOutput.isEmpty else { return nil }
        let data = pendingOutput
        pendingOutput.removeAll()
        return data
    }

    public init(host: Host) {
        self.host = host
    }

    public func connect() {
        disconnect()
        isConnecting = true
        isConnected = false
        isDisconnected = false
        failureInfo = nil
        stages.removeAll()
        pendingOutput.removeAll()
        let attemptID = connectionID

        let targetHost = self.host
        let coreBridge = self.bridge

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sess = coreBridge.connect(
                host: targetHost,
                cols: 80,
                rows: 24,
                autoAcceptNewKeys: true,
                onStage: { [weak self] stageJson in
                    DispatchQueue.main.async {
                        guard let self, self.connectionID == attemptID else { return }
                        self.handleStageJson(stageJson)
                    }
                },
                onOutput: { [weak self] data in
                    DispatchQueue.main.async {
                        guard let self, self.connectionID == attemptID else { return }
                        self.handleRawOutput(data)
                    }
                },
                onAuthInput: { [weak self] name, instructions, prompt, echo in
                    guard let self else { return nil }
                    let waiter = AuthPromptWaiter()
                    let info = AuthPromptInfo(
                        id: UUID(),
                        name: name,
                        instructions: instructions,
                        prompt: prompt,
                        echo: echo
                    )
                    DispatchQueue.main.sync {
                        guard self.connectionID == attemptID else {
                            waiter.complete(nil)
                            return
                        }
                        self.authPromptWaiter = waiter
                        self.authPromptInfo = info
                    }
                    let response = waiter.wait()
                    DispatchQueue.main.sync {
                        if self.authPromptInfo?.id == info.id {
                            self.authPromptInfo = nil
                        }
                        if self.authPromptWaiter === waiter {
                            self.authPromptWaiter = nil
                        }
                    }
                    return response
                },
                onConnectStarted: { [weak self] cancellation in
                    DispatchQueue.main.sync {
                        guard let self, self.connectionID == attemptID else {
                            cancellation.cancel()
                            return
                        }
                        self.connectCancellation = cancellation
                    }
                }
            )

            Task { @MainActor [weak self] in
                guard let self, self.connectionID == attemptID else {
                    sess?.close()
                    return
                }
                self.connectCancellation = nil
                if let sess = sess {
                    self.sessionBridge = sess
                    if let size = self.terminalSize { sess.resize(cols: size.cols, rows: size.rows) }
                } else if self.failureInfo == nil {
                    self.isConnecting = false
                    self.failureInfo = FailureInfo(
                        stage: "Handshake",
                        category: "ConnectError",
                        message: "无法建立连接或凭证无效",
                        suggestion: "请检查主机地址、端口以及网络是否通畅。"
                    )
                }
            }
        }
    }

    public func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sessionBridge?.write(data)
    }

    public func sendBytes(_ bytes: [UInt8]) {
        let data = Data(bytes)
        sessionBridge?.write(data)
    }

    public func sendSpecialKey(_ key: String) {
        switch key {
        case "ESC":
            sendBytes([0x1B])
        case "TAB":
            sendBytes([0x09])
        case "CTRL_C":
            sendBytes([0x03])
        case "CTRL_D":
            sendBytes([0x04])
        case "CTRL_Z":
            sendBytes([0x1A])
        case "UP":
            sendBytes([0x1B, 0x5B, 0x41])
        case "DOWN":
            sendBytes([0x1B, 0x5B, 0x42])
        case "RIGHT":
            sendBytes([0x1B, 0x5B, 0x43])
        case "LEFT":
            sendBytes([0x1B, 0x5B, 0x44])
        default:
            sendInput(key)
        }
    }

    public func resize(cols: UInt32, rows: UInt32) {
        terminalSize = (cols, rows)
        sessionBridge?.resize(cols: cols, rows: rows)
    }

    public func disconnect() {
        connectionID = UUID()
        connectCancellation?.cancel()
        connectCancellation = nil
        authPromptWaiter?.complete(nil)
        authPromptWaiter = nil
        authPromptInfo = nil
        sessionBridge?.close()
        sessionBridge = nil
        isConnecting = false
        isConnected = false
    }

    public func submitAuthInput(_ response: String, for promptID: UUID) {
        guard authPromptInfo?.id == promptID else { return }
        authPromptWaiter?.complete(response)
    }

    public func cancelAuthInput(for promptID: UUID) {
        guard authPromptInfo?.id == promptID else { return }
        authPromptWaiter?.complete(nil)
    }

    private func handleRawOutput(_ data: Data) {
        pendingOutput.append(data)
        outputRevision += 1
    }

    private func handleStageJson(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stage = json["stage"] as? [String: Any],
              let status = stage["status"] as? String else {
            return
        }

        let details = stage["details"] as? [String: Any]

        switch status {
        case "initializing":
            appendStage(status: status, desc: "正在初始化连接链路...", isCurrent: true)

        case "connecting_transport":
            let desc = details?["description"] as? String ?? "网络传输连接中"
            appendStage(status: status, desc: "网络链路: \(desc)", isCurrent: true)

        case "bastion_connecting":
            let hop = details?["hop"] as? Int ?? 1
            let total = details?["total_hops"] as? Int ?? 1
            let name = details?["bastion_name"] as? String ?? ""
            appendStage(status: status, desc: "[\(hop)/\(total)] 连接跳板机: \(name)", isCurrent: true)

        case "bastion_authenticated":
            let hop = details?["hop"] as? Int ?? 1
            let total = details?["total_hops"] as? Int ?? 1
            let name = details?["bastion_name"] as? String ?? ""
            appendStage(status: status, desc: "[\(hop)/\(total)] 跳板机 \(name) 认证通过", isSuccess: true)

        case "bastion_tunnel_ready":
            let hop = details?["hop"] as? Int ?? 1
            let total = details?["total_hops"] as? Int ?? 1
            let target = details?["target"] as? String ?? ""
            appendStage(status: status, desc: "[\(hop)/\(total)] direct-tcpip 隧道已就绪 -> \(target)", isSuccess: true)

        case "cloudflare_handshaking":
            let ep = details?["endpoint"] as? String ?? ""
            let auth = details?["auth_type"] as? String ?? "ServiceToken"
            appendStage(status: status, desc: "Cloudflare 零信任 WSS 握手: \(ep) (\(auth))", isCurrent: true)

        case "cloudflare_authenticated":
            appendStage(status: status, desc: "Cloudflare Access 鉴权成功，安全通道建立", isSuccess: true)

        case "ssh_handshaking":
            let target = details?["target"] as? String ?? ""
            appendStage(status: status, desc: "目标主机 SSH 握手协商 (\(target))", isCurrent: true)

        case "host_key_prompt":
            let h = details?["host"] as? String ?? ""
            let kt = details?["key_type"] as? String ?? ""
            let fp = details?["fingerprint"] as? String ?? ""
            hostKeyPrompt = HostKeyPromptInfo(host: h, keyType: kt, fingerprint: fp)
            appendStage(status: status, desc: "首次连接指纹核验: \(fp)", isSuccess: true)

        case "authenticating_user":
            let user = details?["username"] as? String ?? ""
            let method = details?["method"] as? String ?? ""
            appendStage(status: status, desc: "正在验证用户凭据 (\(user) via \(method))", isCurrent: true)

        case "opening_pty":
            appendStage(status: status, desc: "正在分配虚拟终端 (PTY) 与启动 Shell", isCurrent: true)

        case "connected":
            let target = details?["target"] as? String ?? host.name
            appendStage(status: status, desc: "连接成功！终端会话就绪 (\(target))", isSuccess: true)
            isConnecting = false
            isConnected = true

        case "disconnected":
            let reason = details?["reason"] as? String ?? "远端连接已断开"
            isDisconnected = true
            isConnected = false
            isConnecting = false
            disconnectReason = reason
            appendStage(status: status, desc: "会话结束: \(reason)", isFailed: true)

        case "failed":
            isConnecting = false
            isConnected = false
            let fStage = details?["failed_stage"] as? String ?? "未知阶段"
            let cat = details?["error_category"] as? String ?? "Error"
            let msg = details?["message"] as? String ?? "未知错误"
            let sug = details?["suggestion"] as? String ?? "请检查配置后重试"
            failureInfo = FailureInfo(stage: fStage, category: cat, message: msg, suggestion: sug)
            appendStage(status: status, desc: "[\(fStage)] \(msg)", isFailed: true)

        default:
            break
        }
    }

    private func appendStage(
        status: String,
        desc: String,
        isSuccess: Bool = false,
        isFailed: Bool = false,
        isCurrent: Bool = false
    ) {
        // Mark previous items as no longer current
        for i in 0..<stages.count {
            if stages[i].isCurrent {
                stages[i] = StageItem(
                    status: stages[i].status,
                    description: stages[i].description,
                    isSuccess: true,
                    isFailed: false,
                    isCurrent: false
                )
            }
        }

        stages.append(StageItem(
            status: status,
            description: desc,
            isSuccess: isSuccess,
            isFailed: isFailed,
            isCurrent: isCurrent
        ))
    }
}
