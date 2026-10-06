import CryptoKit
import Foundation

/// 邀请聊天逻辑 —— 与 web InviteChat.tsx + server /invite 协议对齐:
/// 邀请房间是 kind='invite' 的 temp 房间;消息/历史走 TempAPI(密文),
/// 会话密钥在分享链接 #fragment(#k=<b64url>)传递(不经服务器),
/// 加入走 POST /invite/:id/join(6 位验证码,可选账号身份)→ 颁发短期 wsToken。
@MainActor
final class InviteChatViewModel: ObservableObject {
    enum Status {
        case loading
        case needCode
        case chat
        case error(String)
    }

    @Published var status: Status = .loading
    @Published var messages: [DecryptedMsg] = []
    @Published var onlineIps: Int?
    @Published var statusText = "验证中…"
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published var displaySelf = ""

    let inviteId: String
    private let sessionKey: SymmetricKey?
    private let accountToken: String?
    private var roomId: String?
    private var anonId: String?
    private var wsToken: String?
    private var wsUrl = "/ws"
    private var lastSeq = 0
    private var sending = false
    private var hasConnectedBefore = false

    private let ws = WebSocketClient()

    init(inviteId: String, sessionKeyB64url: String?, accountToken: String? = nil) {
        self.inviteId = inviteId
        self.accountToken = accountToken
        self.sessionKey = sessionKeyB64url.flatMap(SessionKeyUtil.fromB64url)
        // 身份复用:本房间已分配的 anonId 持久化,重连/重进不漂移
        // (roomId 未知时用 inviteId 兜底;加入后 roomId 确定再覆盖)
    }

    // MARK: - 生命周期
    func start() async {
        ws.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame: frame) }
        }
        ws.onStatusChange = { [weak self] s in
            Task { @MainActor in self?.handle(status: s) }
        }
        ws.onAuthExpired = { [weak self] in
            Task { @MainActor in self?.refreshWsToken() }
        }
        await verify()
    }

    func leave() {
        ws.disconnect()
    }

    // MARK: - 校验邀请
    private func verify() async {
        status = .loading
        guard sessionKey != nil else {
            status = .error("缺少会话密钥:请使用创建者分享的完整链接(包含 #k= 部分)进入")
            return
        }
        do {
            let info: InviteAPI.InfoResult = try await InviteAPI.info(inviteId)
            guard info.ok, info.roomKind == "invite" else {
                status = .error("邀请无效")
                return
            }
            if info.codeExpired || info.roomExpired || info.roomStatus != "active" {
                status = .error("邀请已过期")
                return
            }
            // 需要验证码
            status = .needCode
        } catch {
            status = .error("验证失败:\(error.localizedDescription)")
        }
    }

    // MARK: - 验证码 + 加入
    func join(code: String) async {
        guard let key = sessionKey else {
            errorMessage = "缺少会话密钥"
            return
        }
        status = .loading
        do {
            // 携带持久化 anonId(防重连刷新变新访客)+ 可选账号 token
            let persistedAnon: String? = roomId.flatMap { UserDefaults.standard.string(forKey: "anon:\($0)") }
            let j: InviteAPI.JoinResult = try await InviteAPI.join(inviteId, code: code,
                                                                   token: accountToken,
                                                                   anonId: persistedAnon)
            roomId = j.roomId
            anonId = j.anonId
            displaySelf = j.displayName
            wsToken = j.wsToken
            wsUrl = j.wsUrl
            UserDefaults.standard.set(j.anonId, forKey: "anon:\(j.roomId)")
            // 持久化验证码:wsToken 失效(>5min)后可免重输直接重 join
            UserDefaults.standard.set(code, forKey: "lmh.invite.code.\(inviteId)")

            // 持久化密钥(刷新后保留聊天记录)
            let b64 = SessionKeyUtil.b64url(key)
            UserDefaults.standard.set(b64, forKey: "lmh.invite.key.\(j.roomId)")

            // 拉历史(temp 房间)并解密
            status = .chat
            await loadHistory(key: key, roomId: j.roomId)
            connectWs()
        } catch let e as ApiError where e.status == 401 {
            errorMessage = "验证码错误,请重试"
        } catch let e as ApiError where e.status == 429 {
            errorMessage = "尝试次数过多,请稍后再试"
        } catch {
            errorMessage = "加入失败:\(error.localizedDescription)"
        }
    }

    // MARK: - 历史
    private func loadHistory(key: SymmetricKey, roomId: String) async {
        do {
            let h: TempAPI.HistoryResult = try await TempAPI.history(roomId, afterSeq: 0, limit: 500)
            append(history: h.messages, key: key, roomId: roomId, replacing: true)
            isReady = true
            statusText = "已连接 · 端到端加密"
        } catch {
            statusText = "拉取历史失败:\(error.localizedDescription)"
        }
    }

    private func pullNew(key: SymmetricKey, roomId: String) async {
        do {
            let h: TempAPI.HistoryResult = try await TempAPI.history(roomId, afterSeq: lastSeq, limit: 100)
            append(history: h.messages, key: key, roomId: roomId, replacing: false)
        } catch {}
    }

    private func append(history: [TempMsg], key: SymmetricKey, roomId: String, replacing: Bool) {
        var newItems: [DecryptedMsg] = []
        for m in history where m.seq > lastSeq {
            guard let dec = decrypt(m, key: key, roomId: roomId) else { continue }
            newItems.append(dec)
        }
        newItems.sort { $0.seq < $1.seq }
        guard !newItems.isEmpty else { return }
        lastSeq = max(lastSeq, newItems.last!.seq)
        if replacing { messages = newItems }
        else { messages.append(contentsOf: newItems); messages.sort { $0.seq < $1.seq } }
    }

    private func decrypt(_ m: TempMsg, key: SymmetricKey, roomId: String) -> DecryptedMsg? {
        let payload = MessageCrypto.EncryptedPayload(iv: m.iv, ct: m.cipher)
        guard let raw = try? MessageCrypto.decryptMessage(sessionKey: key, payload: payload,
                                                          roomId: roomId, seq: m.seq, ts: m.ts) else { return nil }
        let body = MessageCrypto.decodeMessageBody(raw: raw)
        let mine = m.anonId == anonId
        return DecryptedMsg(id: m.id, seq: m.seq,
                            label: mine ? "我" : LabelUtil.label(for: m.anonId),
                            mine: mine,
                            text: body.attachment?.name ?? body.text ?? "(无法解析的消息)",
                            ts: m.ts, kind: "msg")
    }

    // MARK: - WebSocket
    private func connectWs() {
        guard let token = wsToken, let url = buildWsURL() else {
            statusText = "无法连接实时服务"
            return
        }
        ws.connect(url: url)
    }

    private func buildWsURL() -> URL? {
        let resolved: URL?
        if wsUrl.hasPrefix("ws://") || wsUrl.hasPrefix("wss://") {
            resolved = URL(string: wsUrl)
        } else {
            let path = wsUrl.hasPrefix("/") ? wsUrl : "/\(wsUrl)"
            resolved = URL(string: "wss://\(AppEnvironment.host)\(path)")
        }
        guard let base = resolved, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = comps.queryItems ?? []
        if let token = wsToken, !items.contains(where: { $0.name == "wsToken" || $0.name == "token" }) {
            items.append(URLQueryItem(name: "wsToken", value: token))
        }
        comps.queryItems = items
        return comps.url
    }

    private func handle(status: WebSocketClient.Status) {
        switch status {
        case .connected:
            statusText = "已连接 · 端到端加密"
            if hasConnectedBefore, let key = sessionKey, let roomId {
                Task { await pullNew(key: key, roomId: roomId) }
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
            if let key = sessionKey, let roomId { Task { await pullNew(key: key, roomId: roomId) } }
        case "presence":
            onlineIps = frame.onlineIps
        case "error":
            if let e = frame.error { statusText = "服务器:\(e)" }
        default:
            break
        }
    }

    private func refreshWsToken() {
        statusText = "令牌失效,重新连接…"
        wsToken = nil
        if let roomId, let key = sessionKey {
            Task {
                await join(code: UserDefaults.standard.string(forKey: "lmh.invite.code.\(self.inviteId)") ?? "")
            }
        }
    }

    // MARK: - 发送
    func send(_ text: String) async {
        guard let key = sessionKey, let roomId, let anon = anonId, !sending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending = true
        defer { sending = false }
        let ts = TimeUtil.nowMs
        let targetSeq = lastSeq + 1
        do {
            let enc = try MessageCrypto.encryptMessage(sessionKey: key,
                                                       plaintext: MessageCrypto.encodeMessageBody(text: trimmed),
                                                       roomId: roomId, seq: targetSeq, ts: ts)
            let r: TempAPI.SendResult = try await TempAPI.send(roomId, iv: enc.iv, cipher: enc.ct,
                                                               anonId: anon, seq: targetSeq, ts: ts)
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
}
