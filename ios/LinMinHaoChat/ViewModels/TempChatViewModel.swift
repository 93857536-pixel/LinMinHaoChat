import CryptoKit
import Foundation

/// 临时聊天逻辑 —— 与 web TempChat 行为对齐:
/// create → join(身份复用) → 拉历史 → WS 连接 → 发消息(seq 冲突自愈)→ WS 收帧拉增量
@MainActor
final class TempChatViewModel: ObservableObject {
    @Published var messages: [DecryptedMsg] = []
    @Published var lastSeq = 0
    @Published var onlineIps: Int?
    @Published var statusText = "连接中…"
    @Published var isReady = false

    let roomId: String
    let sessionKey: SymmetricKey
    private(set) var anonId: String?

    private let ws = WebSocketClient()
    private var sending = false
    private var hasConnectedBefore = false

    init(roomId: String, sessionKey: SymmetricKey) {
        self.roomId = roomId
        self.sessionKey = sessionKey
        // 身份复用:本房间已分配的 anonId 持久化,重连/重进不漂移
        if let saved = UserDefaults.standard.string(forKey: "lmh.anon.\(roomId)") {
            self.anonId = saved
        }
    }

    func start() async {
        ws.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame: frame) }
        }
        ws.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.handle(status: status) }
        }
        await join()
    }

    private func join() async {
        statusText = "加入房间…"
        do {
            let r: TempAPI.JoinResult = try await TempAPI.join(roomId, anonId: anonId)
            anonId = r.anonId
            UserDefaults.standard.set(r.anonId, forKey: "lmh.anon.\(roomId)")
            await loadHistory()
            connectWs(wsUrl: r.wsUrl)
        } catch {
            statusText = "加入失败:\(error.localizedDescription)"
        }
    }

    private func connectWs(wsUrl: String) {
        // 服务器返回的 wsUrl 可能是相对路径("/ws")——相对则按 wss://linminhao.top 解析
        let resolved: URL?
        if wsUrl.hasPrefix("ws://") || wsUrl.hasPrefix("wss://") {
            resolved = URL(string: wsUrl)
        } else {
            let path = wsUrl.hasPrefix("/") ? wsUrl : "/\(wsUrl)"
            resolved = URL(string: "wss://\(AppEnvironment.host)\(path)")
        }
        guard let url = resolved else {
            statusText = "服务器返回了无效的 WebSocket 地址"
            return
        }
        ws.connect(url: url)
    }

    private func handle(status: WebSocketClient.Status) {
        switch status {
        case .connected:
            statusText = "已连接 · 端到端加密"
            if hasConnectedBefore {
                // 断线重连:重新 join 拿新一次性令牌 + 补收离线消息(web reconnectWs 同策略)
                reconnectToServer()
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
            // WS 仅推送事件,收到后拉增量(与 web pullNew 一致)
            Task { await pullNew() }
        case "presence":
            onlineIps = frame.onlineIps
        case "error":
            if let e = frame.error { statusText = "服务器:\(e)" }
        default:
            break
        }
    }

    private func loadHistory() async {
        do {
            let h: TempAPI.HistoryResult = try await TempAPI.history(roomId, afterSeq: 0, limit: 100)
            append(history: h.messages, replacing: true)
            isReady = true
            statusText = "已连接 · 端到端加密"
        } catch {
            statusText = "拉取历史失败:\(error.localizedDescription)"
        }
    }

    private func pullNew() async {
        do {
            let h: TempAPI.HistoryResult = try await TempAPI.history(roomId, afterSeq: lastSeq, limit: 100)
            append(history: h.messages, replacing: false)
        } catch {
            // 拉取失败等下次事件重试(web 同策略:断线期间只靠重连后 pullNew 补收)
        }
    }

    private func append(history: [TempMsg], replacing: Bool) {
        var newItems: [DecryptedMsg] = []
        for m in history where m.seq > lastSeq {
            guard let decrypted = decrypt(m) else { continue }
            newItems.append(decrypted)
        }
        newItems.sort { $0.seq < $1.seq }
        if !newItems.isEmpty {
            lastSeq = max(lastSeq, newItems.last!.seq)
            if replacing {
                messages = newItems
            } else {
                messages.append(contentsOf: newItems)
                messages.sort { $0.seq < $1.seq }
            }
        }
    }

    private func decrypt(_ m: TempMsg) -> DecryptedMsg? {
        let payload = MessageCrypto.EncryptedPayload(iv: m.iv, ct: m.cipher)
        guard let raw = try? MessageCrypto.decryptMessage(sessionKey: sessionKey,
                                                          payload: payload, roomId: roomId,
                                                          seq: m.seq, ts: m.ts) else { return nil }
        let body = MessageCrypto.decodeMessageBody(raw: raw)
        let text = body.attachment?.name ?? body.text ?? "(无法解析的消息)"
        let mine = (m.anonId == anonId) && !(m.anonId?.isEmpty ?? true)
        return DecryptedMsg(id: m.id, seq: m.seq,
                            label: mine ? "我" : LabelUtil.label(for: m.anonId),
                            mine: mine, text: text, ts: m.ts, kind: "msg")
    }

    /// 发送文本消息。seq 冲突(409)时用服务器期望 seq 对齐后重试(最多 3 次)。
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }

        let ts = TimeUtil.nowMs
        let targetSeq = lastSeq + 1
        do {
            let enc = try MessageCrypto.encryptMessage(sessionKey: sessionKey,
                                                       plaintext: MessageCrypto.encodeMessageBody(text: trimmed),
                                                       roomId: roomId, seq: targetSeq, ts: ts)
            let r: TempAPI.SendResult = try await TempAPI.send(roomId, iv: enc.iv, cipher: enc.ct,
                                                               anonId: anonId ?? "", seq: targetSeq, ts: ts)
            lastSeq = r.seq
            messages.append(DecryptedMsg(id: r.id, seq: r.seq, label: "我", mine: true,
                                         text: trimmed, ts: r.ts, kind: "msg"))
        } catch let e as ApiError where e.status == 409 {
            // 序号冲突:以服务器期望 seq 对齐,重新加密(409 的 AAD 已含旧 seq,必须重算)
            if let expected = e.data?["seq"] as? Int {
                lastSeq = expected - 1
            }
            if lastSeq < targetSeq - 1 {
                // 对齐后重试(最多一次,避免死循环)
                await send(text)
            }
        } catch {
            statusText = "发送失败:\(error.localizedDescription)"
        }
    }

    func leave() {
        ws.disconnect()
    }

    /// 重连后重新 join 拿新一次性 wsToken(web reconnectWs 逻辑)
    private func reconnectToServer() {
        Task {
            do {
                let r: TempAPI.JoinResult = try await TempAPI.join(roomId, anonId: anonId)
                if anonId != r.anonId {
                    anonId = r.anonId
                    UserDefaults.standard.set(r.anonId, forKey: "lmh.anon.\(roomId)")
                }
                await pullNew()
            } catch {
                // join 限流等场景:保持现有连接即可,下轮重连再试
            }
        }
    }
}
