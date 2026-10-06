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
    /// read 帧:reader 的 userId
    let userId: Int?
    /// read 帧:已读到的最新 seq
    let lastSeq: Int?
    /// 消息文本(当 kind=msg 且有 plainText 时直接展示,跳过解密)
    let plainText: String?

    private enum CodingKeys: String, CodingKey {
        case type, roomId, seq, id, senderId, anonId, ts, kind, onlineIps, online, serverTime, t, error
        case userId, lastSeq, plainText
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
        userId = try c.decodeIfPresent(Int.self, forKey: .userId)
        lastSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeq)
        plainText = try c.decodeIfPresent(String.self, forKey: .plainText)
    }

    private static func decodeOnline(from c: KeyedDecodingContainer<CodingKeys>) -> [String]? {
        if let strs = try? c.decodeIfPresent([String].self, forKey: .online) { return strs }
        if let nums = try? c.decodeIfPresent([Int].self, forKey: .online) { return nums.map(String.init) }
        return nil
    }
}

/// URLSessionWebSocketDelegate 桥接:捕获 open / close code(4001 等)
private final class WSDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((Int) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // URLSessionWebSocketTask.CloseCode(rawValue: 4001) 可用;rawValue 就是整数
        onClose?(closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 传输级错误(断网/超时)不算服务器主动 close;此处仅当未收到 close 帧时触发
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            onClose?(-1)
        }
    }
}

/// WebSocket 客户端 —— 与 web/src/ws.ts 行为一致:
/// - 连接 wss://chat.linminhao.top/ws?wsToken=<短令牌>
/// - 25s 心跳 ping
/// - 收到 msg 帧后由上层拉取历史增量(pullNew,本端不做补发)
/// - 断线指数退避重连(1s→15s);**复用同一短令牌**(服务器 5 分钟内允许重复连接,
///   避免每次重连重新 join 触发限流 429);令牌失效(服务器 4001 关闭)时由上层重新 join
final class WebSocketClient {
    enum Status: Equatable {
        case idle, connecting, connected, reconnecting, closed
    }

    var onFrame: ((WsFrame) -> Void)?
    var onStatusChange: ((Status) -> Void)?
    /// 服务器以 4001 关闭(令牌失效/过期)时回调,上层应重新 join 拿新令牌并更新 URL
    var onAuthExpired: (() -> Void)?

    private(set) var status: Status = .idle {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var delegate: WSDelegate?
    private var heartbeat: Timer?
    private var reconnectAttempt = 0
    private var reconnectWork: Task<Void, Never>?
    private var shouldReconnect = false
    private var pendingUrl: URL?
    /// 重连退避上限(秒)。默认 15;上层在 429 限流时调大(如 60),避免重连风暴打爆限流。
    var maxReconnectDelay = 15

    init() {
        let d = WSDelegate()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: d, delegateQueue: .main)
        delegate = d
        d.onOpen = { [weak self] in self?.handleOpen() }
        d.onClose = { [weak self] code in self?.handleDisconnect(closeCode: code) }
    }

    deinit {
        heartbeat?.invalidate()
        session.invalidateAndCancel()
    }

    /// 连接(wsUrl 通常来自 join 返回的 wsUrl + 短令牌)
    func connect(url: URL) {
        pendingUrl = url
        shouldReconnect = true
        reconnectAttempt = 0
        open(url: url)
    }

    /// 更新待重连 URL(令牌失效 4001 后上层重新 join 拿到新短令牌时调用)
    func updatePendingUrl(_ url: URL) {
        pendingUrl = url
    }

    /// 主动断开(离开房间,不再重连)
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

    private func open(url: URL) {
        status = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        startHeartbeat()
        receiveLoop(task: task)
    }

    private func handleOpen() {
        status = .connected
        reconnectAttempt = 0
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
                // 传输级断开:delegate 的 didCompleteWithError 会触发 handleDisconnect(-1)
                break
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

    private func handleDisconnect(closeCode: Int) {
        heartbeat?.invalidate()
        heartbeat = nil
        task = nil
        // 服务器 4001 = 短令牌失效/过期:通知上层重新 join 拿新令牌(web 同策略)
        if closeCode == 4001 {
            onAuthExpired?()
        }
        guard shouldReconnect else {
            status = .closed
            return
        }
        status = .reconnecting
        let delay = min(maxReconnectDelay, 1 << reconnectAttempt)  // 1s, 2s, 4s ... 上限封顶
        reconnectAttempt += 1
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.shouldReconnect, let url = self.pendingUrl else { return }
            self.open(url: url)
        }
    }
}
