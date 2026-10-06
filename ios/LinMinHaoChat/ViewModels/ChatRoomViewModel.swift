import CryptoKit
import Foundation
import SwiftUI

/// 账号聊天逻辑 —— 与 web Chat.tsx 行为对齐:
/// 拉密钥包(我的设备)→ ECDH 解包会话密钥 → 拉历史 → WS(jwt)订阅房间 → 发消息(seq 冲突自愈)
@MainActor
final class ChatRoomViewModel: ObservableObject {
    @Published var messages: [DecryptedMsg] = []
    @Published var onlineIps: Int?
    @Published var statusText = "连接中…"
    @Published var isReady = false
    @Published var errorMessage: String?

    let roomId: String
    private let token: String        // 账号 JWT
    private let identity: DeviceIdentity
    private var keyCache: SymmetricKey?
    private var lastSeq = 0
    private var sending = false
    private var hasConnectedBefore = false
    /// 服务端上报的该用户已读到的最高 seq(0 = 未知)
    private var readSeq = 0

    private let ws = WebSocketClient()

    init(roomId: String, token: String, identity: DeviceIdentity) {
        self.roomId = roomId
        self.token = token
        self.identity = identity
    }

    // MARK: - 生命周期
    func start() async {
        ws.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame: frame) }
        }
        ws.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.handle(status: status) }
        }
        ws.onAuthExpired = { [weak self] in
            Task { @MainActor in self?.refreshWsToken() }
        }
        await openRoom()
    }

    func leave() {
        ws.disconnect()
    }

    // MARK: - 房间初始化
    private func openRoom() async {
        statusText = "加载房间…"
        guard let myKeys = try? IdentityStore.load() else {
            errorMessage = "本机身份密钥缺失,请重新登录"
            return
        }
        do {
            // 1. 拉取"我的"设备 wrapped keys,逐个尝试 ECDH 解包
            let keysResult = try await KeysAPI.roomKeys(roomId, deviceId: identity.deviceId, token: token)
            var key: SymmetricKey?
            for wrapped in keysResult.keys {
                do {
                    key = try IdentityCrypto.unwrapSessionKey(wrapped: wrapped, myKeys: myKeys)
                    if key != nil { break }
                } catch { /* 尝试下一个设备密钥 */ }
            }
            guard let sessionKey = key else {
                errorMessage = "无法解包会话密钥:你不是本房间成员"
                return
            }
            keyCache = sessionKey

            // 2. 拉取历史消息
            await loadHistory()

            // 3. 连接 WebSocket(账号 JWT)
            connectWs()
        } catch {
            errorMessage = "加载失败:\(error.localizedDescription)"
        }
    }

    private func loadHistory() async {
        do {
            let result = try await ChatAPI.history(roomId, afterSeq: 0, limit: 100, token: token)
            append(messages: result.messages, replacing: true)
            isReady = true
            statusText = "已连接 · 端到端加密"
        } catch {
            statusText = "拉取历史失败:\(error.localizedDescription)"
        }
    }

    private func pullNew() async {
        do {
            let result = try await ChatAPI.history(roomId, afterSeq: lastSeq, limit: 100, token: token)
            append(messages: result.messages, replacing: false)
        } catch {
            // 静默,等下次事件重试
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
        guard !newItems.isEmpty else { return }

        lastSeq = max(lastSeq, newItems.last!.seq)
        if replacing {
            self.messages = newItems
        } else {
            self.messages.append(contentsOf: newItems)
            self.messages.sort { $0.seq < $1.seq }
        }
        // 标记已读(元数据,不阻塞 UI)
        if lastSeq > 0 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await ChatAPI.markRead(self.roomId, lastSeq: self.lastSeq, token: self.token)
            }
        }
        // 更新聊天列表预览(本地缓存,不上传)
        updatePreview()
    }

    private func decrypt(_ m: ChatMsg, sessionKey: SymmetricKey) -> DecryptedMsg? {
        let payload = MessageCrypto.EncryptedPayload(iv: m.iv, ct: m.cipher)
        guard let raw = try? MessageCrypto.decryptMessage(sessionKey: sessionKey, payload: payload, roomId: roomId, seq: m.seq, ts: m.ts) else {
            return nil
        }
        let body = MessageCrypto.decodeMessageBody(raw: raw)

        let mine = m.senderId == AppState.shared.userId
        let label = mine ? "我" : (m.senderId.map { "账号\($0)" } ?? "未知")

        var att: DecryptedMsg.AttachmentInfo?
        if let a = body.attachment {
            att = DecryptedMsg.AttachmentInfo(attId: a.attId ?? "", name: a.name, size: a.size, mime: a.mime)
        }

        return DecryptedMsg(
            id: m.id, seq: m.seq, label: label, mine: mine,
            text: body.attachment?.name ?? body.text ?? "(无法解析的消息)",
            ts: m.ts, kind: m.kind, att: att
        )
    }

    // MARK: - WebSocket(账号:携带 JWT)
    private func connectWs() {
        guard let url = buildWsURL() else {
            errorMessage = "无法连接实时服务"
            return
        }
        ws.connect(url: url)
    }

    private func buildWsURL() -> URL? {
        guard var comps = URLComponents(string: "wss://\(AppEnvironment.host)/ws") else { return nil }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    /// 连接建立后订阅房间
    func subscribe() {
        ws.send(["type": "subscribe", "roomId": roomId])
    }

    private func handle(status: WebSocketClient.Status) {
        switch status {
        case .connected:
            subscribe()
            statusText = "已连接 · 端到端加密"
            if hasConnectedBefore {
                Task { await pullNew() }
            }
            hasConnectedBefore = true
        case .reconnecting:
            statusText = "连接断开,正在重连…"
        case .closed:
            statusText = "连接已关闭"
        case .idle, .connecting:
            break
        }
    }

    private func handle(frame: WsFrame) {
        switch frame.type {
        case "msg":
            Task { await pullNew() }
        case "presence":
            onlineIps = frame.onlineIps
        case "read":
            // 服务端推送的 read 帧:userId 是 reader,userId=me 且 lastSeq>= 我的最后 seq 时,把本机所有 mine 消息标为已读
            if let readerId = frame.userId, let lastSeq = frame.lastSeq, readerId == AppState.shared.userId {
                self.readSeq = lastSeq
                // 刷新列表中 mine 消息的 isRead 状态
                messages = messages.map { m in
                    var mm = m
                    if mm.mine && m.seq <= lastSeq { mm.isRead = true }
                    return mm
                }
            }
        case "subscribed":
            statusText = "已连接 · 端到端加密"
        case "error":
            if let e = frame.error { statusText = "服务器:\(e)" }
        default:
            break
        }
    }

    private func refreshWsToken() {
        // 账号 JWT 长期有效,4001 极少发生;此处重订一次
        statusText = "重新连接…"
        Task { await pullNew() }
    }

    // MARK: - 发送
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, let sessionKey = keyCache else { return }
        sending = true
        defer { sending = false }

        let ts = TimeUtil.nowMs
        let targetSeq = lastSeq + 1
        do {
            let enc = try MessageCrypto.encryptMessage(sessionKey: sessionKey,
                                                       plaintext: MessageCrypto.encodeMessageBody(text: trimmed),
                                                       roomId: roomId, seq: targetSeq, ts: ts)
            let r = try await ChatAPI.send(roomId, iv: enc.iv, cipher: enc.ct,
                                           seq: targetSeq, ts: ts, kind: "msg", token: token)
            lastSeq = r.seq
            messages.append(DecryptedMsg(id: r.id, seq: r.seq, label: "我", mine: true,
                                         text: trimmed, ts: r.ts, kind: "msg"))
        } catch let e as ApiError where e.status == 409 {
            if let expected = e.data?["seq"] as? Int {
                lastSeq = expected - 1
                if lastSeq < targetSeq - 1 { await send(text) }
            }
        } catch {
            errorMessage = "发送失败:\(error.localizedDescription)"
        }
    }

    // MARK: - 删除单条消息(仅本地,服务器不删)
    func deleteMessage(_ msgId: String) {
        messages.removeAll { $0.id == msgId }
    }

    // MARK: - 列表预览(本地缓存,不上传;进入/离开聊天通知列表刷新未读)
    private func updatePreview() {
        guard let last = messages.last else { return }
        ChatPreviewStore.shared.set(roomId, text: last.text, ts: last.ts, senderLabel: last.mine ? nil : last.label)
        AppState.shared.chatListVersion += 1
    }
}
