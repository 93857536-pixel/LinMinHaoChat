import Foundation

/// WebSocket 帧 —— 与 web/src/ws.ts 的 WsMsg 对应
struct WsFrame: Decodable {
    let type: String
    let roomId: String?
    let seq: Int?
    let id: String?
    let senderId: Int?
    let anonId: String?
    let ts: Int64?
    let kind: String?
    let onlineIps: Int?
    let online: [String]?
    let serverTime: Int64?
    let t: Int64?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case type, roomId, seq, id, senderId, anonId, ts, kind, onlineIps, online, serverTime, t, error
    }

    /// online 可能是 [number] 或 [string],统一转成 [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        roomId = try c.decodeIfPresent(String.self, forKey: .roomId)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        senderId = try c.decodeIfPresent(Int.self, forKey: .senderId)
        anonId = try c.decodeIfPresent(String.self, forKey: .anonId)
        ts = try c.decodeIfPresent(Int64.self, forKey: .ts)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        onlineIps = try c.decodeIfPresent(Int.self, forKey: .onlineIps)
        online = Self.decodeOnline(from: c)
        serverTime = try c.decodeIfPresent(Int64.self, forKey: .serverTime)
        t = try c.decodeIfPresent(Int64.self, forKey: .t)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    private static func decodeOnline(from c: KeyedDecodingContainer<CodingKeys>) -> [String]? {
        if let strs = try? c.decodeIfPresent([String].self, forKey: .online) { return strs }
        if let nums = try? c.decodeIfPresent([Int].self, forKey: .online) { return nums.map(String.init) }
        return nil
    }
}

/// WebSocket 客户端 —— 与 web/src/ws.ts 行为一致:
/// - 连接 wss://linminhao.top/ws?token=<wsToken>
/// - 25s 心跳 ping
/// - 收到 msg 帧后由上层拉取历史增量(pullNew,本端不做补发)
/// - 断线指数退避重连(1s→15s),重连后重新 join 拿新一次性令牌
final class WebSocketClient {
    enum Status: Equatable {
        case idle, connecting, connected, reconnecting, closed
    }

    var onFrame: ((WsFrame) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .idle {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var reconnectAttempt = 0
    private var reconnectWork: Task<Void, Never>?
    private var shouldReconnect = false
    private var pendingUrl: URL?

    /// 连接(wsUrl 通常来自 join 返回的 wsUrl,绝对地址)
    func connect(url: URL) {
        pendingUrl = url
        shouldReconnect = true
        reconnectAttempt = 0
        open(url: url)
    }

    private func open(url: URL) {
        status = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        startHeartbeat()
        receiveLoop(task: task)
    }

    /// 断开(主动离开房间,不再重连)
    func disconnect() {
        shouldReconnect = false
        reconnectWork?.cancel()
        heartbeat?.invalidate()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .closed
    }

    /// 发送任意 JSON 可序列化对象
    func send(_ object: [String: Any]) {
        guard status == .connected, let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let s) = message,
                   let data = s.data(using: .utf8),
                   let frame = try? JSONDecoder().decode(WsFrame.self, from: data) {
                    self.onFrame?(frame)
                }
                if self.task === task { self.receiveLoop(task: task) }
            case .failure:
                self.handleDisconnect()
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            self?.send(["type": "ping"])
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func handleDisconnect() {
        heartbeat?.invalidate()
        heartbeat = nil
        task = nil
        guard shouldReconnect else {
            status = .closed
            return
        }
        status = .reconnecting
        let delay = min(15, 1 << reconnectAttempt)  // 1s, 2s, 4s ... 15s 封顶
        reconnectAttempt += 1
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.shouldReconnect, let url = self.pendingUrl else { return }
            self.open(url: url)
        }
    }
}
