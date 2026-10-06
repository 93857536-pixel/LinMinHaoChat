import CryptoKit
import Foundation

// MARK: - 账号聊天 ViewModel
@MainActor
final class ChatRoomViewModel: ObservableObject {
    // MARK: - Published State
    @Published var messages: [DecryptedMsg] = []
    @Published var onlineIps: Int?
    @Published var statusText = "连接中…"
    @Published var isReady = false
    @Published var errorMessage: String?
    
    // MARK: - Properties
    let roomId: String
    private let token: String
    private let identity: DeviceIdentity
    private var keyCache: SymmetricKey?
    private var lastSeq = 0
    private var sending = false
    private var hasConnectedBefore = false
    
    private var ws: WebSocketClient?
    
    // MARK: - Init
    init(roomId: String, token: String, identity: DeviceIdentity) {
        self.roomId = roomId
        self.token = token
        self.identity = identity
    }
    
    // MARK: - Lifecycle
    func start() async {
        let wsClient = WebSocketClient()
        wsClient.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handleFrame(frame: frame) }
        }
        wsClient.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.handleStatus(status: status) }
        }
        wsClient.onAuthExpired = { [weak self] in
            Task { @MainActor in self?.refreshWsToken() }
        }
        self.ws = wsClient
        
        await openRoom()
    }
    
    func leave() {
        ws?.disconnect()
        ws = nil
    }
    
    // MARK: - Private Methods
    private func openRoom() async {
        statusText = "加载房间…"
        do {
            // 1. 解包会话密钥
            let keysResult = try await KeysAPI.keys(roomId, deviceId: identity.deviceId, token: token)
            guard !keysResult.devices.isEmpty else {
                errorMessage = "无法解包会话密钥：你可能不是本设备的授权成员"
                return
            }
            
            // 尝试用每个设备密钥解包
            var key: SymmetricKey?
            for device in keysResult.devices {
                do {
                    guard let myKeys = try? IdentityStore.load() else { continue }
                    key = try IdentityCrypto.unwrapSessionKey(wrapped: device.device_id, myKeys: myKeys)
                    if key != nil { break }
                } catch {
                    continue
                }
            }
            guard let sessionKey = key else {
                errorMessage = "无法解包会话密钥：密钥不匹配"
                return
            }
            keyCache = sessionKey
            
            // 2. 拉取历史消息
            await loadHistory()
            
            // 3. 连接 WebSocket
            connectWs()
        } catch {
            errorMessage = "加载失败:\(error.localizedDescription)"
        }
    }
    
    private func loadHistory() async {
        do {
            let result = try await ChatAPI.history(roomId, token: token, afterSeq: 0, limit: 100)
            append(messages: result.messages, replacing: true)
            isReady = true
            statusText = "已连接 · 端到端加密"
        } catch {
            statusText = "拉取历史失败:\(error.localizedDescription)"
        }
    }
    
    private func pullNew() async {
        do {
            let result = try await ChatAPI.history(roomId, token: token, afterSeq: lastSeq, limit: 100)
            append(messages: result.messages, replacing: false)
        } catch {
            // 静默失败，等下次事件重试
        }
    }
    
    private func append(messages: [ChatMsg], replacing: Bool) {
        var newItems: [DecryptedMsg] = []
        guard let sessionKey = keyCache else { return }
        
        for m in messages where m.seq > lastSeq {
            guard let decrypted = decrypt(m, sessionKey: sessionKey) else { continue }
            newItems.append(decrypted)
        }
        newItems.sort { $0.seq < $1.seq }
        if !newItems.isEmpty {
            lastSeq = max(lastSeq, newItems.last!.seq)
            if replacing {
                self.messages = newItems
            } else {
                self.messages.append(contentsOf: newItems)
                self.messages.sort { $0.seq < $1.seq }
            }
            // 标记已读(异步，不阻塞消息显示)
            if lastSeq > 0 {
                Task { @MainActor [roomId, lastSeq, token] in
                    try? await ChatAPI.markRead(roomId, lastSeq: lastSeq, token: token)
                }
            }
        }
    }
    
    private func decrypt(_ m: ChatMsg, sessionKey: SymmetricKey) -> DecryptedMsg? {
        let payload = MessageCrypto.EncryptedPayload(iv: m.iv, ct: m.cipher)
        guard let raw = try? MessageCrypto.decryptMessage(sessionKey: sessionKey, payload: payload, roomId: roomId, seq: m.seq, ts: m.ts) else {
            return nil
        }
        let body = MessageCrypto.decodeMessageBody(raw: raw)
        
        let userId = AppState.shared.userId ?? 0
        let mine = m.senderId == userId
        let label = mine ? "我" : (m.senderId.map { "用户 #\($0)" } ?? "未知")
        
        return DecryptedMsg(
            id: m.id,
            seq: m.seq,
            label: label,
            mine: mine,
            text: body.text ?? "(无法解析的消息)",
            ts: m.ts,
            kind: m.kind
        )
    }
    
    // MARK: - WebSocket
    private func connectWs() {
        guard let url = buildWsURL(wsToken: token) else {
            errorMessage = "服务器返回了无效的 WebSocket 地址"
            return
        }
        ws?.connect(url: url)
    }
    
    private func buildWsURL(wsToken: String) -> URL? {
        let url = URL(string: "wss://\(AppEnvironment.host)/ws")!
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        comps.queryItems = [URLQueryItem(name: "wsToken", value: wsToken)]
        return comps.url
    }
    
    private func handleStatus(status: WebSocketClient.Status) {
        switch status {
        case .connected:
            statusText = "已连接 · 端到端加密"
            if hasConnectedBefore {
                Task { await pullNew() }
            }
            hasConnectedBefore = true
        case .reconnecting:
            statusText = "连接断开，正在重连…"
        case .closed:
            statusText = "连接已关闭"
        case .idle, .connecting:
            break
        }
    }
    
    private func handleFrame(frame: WsFrame) {
        switch frame.type {
        case "msg":
            Task { await pullNew() }
        case "presence":
            onlineIps = frame.onlineIps
        case "read":
            // 已读回执，无需处理
            break
        case "error":
            if let e = frame.error { statusText = "服务器:\(e)" }
        default:
            break
        }
    }
    
    private func refreshWsToken() {
        // TODO: 重新 join 获取新令牌
        statusText = "令牌失效，重新连接…"
    }
    
    // MARK: - Actions
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, let sessionKey = keyCache else { return }
        sending = true
        defer { sending = false }
        
        let ts = TimeUtil.nowMs
        let targetSeq = lastSeq + 1
        
        do {
            let enc = try MessageCrypto.encryptMessage(
                sessionKey: sessionKey,
                plaintext: MessageCrypto.encodeMessageBody(text: trimmed),
                roomId: roomId,
                seq: targetSeq,
                ts: ts
            )
            let r = try await ChatAPI.send(roomId, iv: enc.iv, cipher: enc.ct, seq: targetSeq, ts: ts, kind: "msg", token: token)
            lastSeq = r.seq
            
            // 本地追加
            messages.append(DecryptedMsg(
                id: r.id, seq: r.seq, label: "我", mine: true,
                text: trimmed, ts: r.ts, kind: "msg"
            ))
        } catch let e as ApiError where e.status == 409 {
            // 序号冲突
            if let expected = e.data?["seq"] as? Int {
                lastSeq = expected - 1
                await send(text)
            }
        } catch {
            errorMessage = "发送失败:\(error.localizedDescription)"
        }
    }
}
