import Foundation

// MARK: - 全局应用状态
@MainActor
final class AppState: ObservableObject {
    /// 单例访问
    static let shared = AppState()

    /// 进入后台标志(触发隐私模糊层)
    @Published var isBackgrounded = false

    /// 账号会话(登录后设置;账号聊天下一阶段接线)
    @Published var authToken: String?
    @Published var sessionId: String?
    @Published var userId: Int?
    @Published var userHandle: String?

    /// 当前设备身份
    @Published var identity: DeviceIdentity?

    /// 网络状态
    @Published var isConnected: Bool = true
    @Published var connectionStatus: ConnectionStatus = .connected

    enum ConnectionStatus: String {
        case disconnected = "网络断开"
        case reconnecting = "正在重连…"
        case connected = "已连接"
    }

    /// 网络监测定时器
    private var networkTimer: Timer?
    private var networkTask: Task<Void, Never>?

    /// 当前是否有账号登录态(Keychain 中持久化 token)
    init() {
        // 恢复认证信息
        if let tokenData = KeychainStore.load(account: "lmh.auth.token") {
            authToken = String(data: tokenData, encoding: .utf8)
        }
        if let sessionData = KeychainStore.load(account: "lmh.auth.session") {
            sessionId = String(data: sessionData, encoding: .utf8)
        }

        // 尝试加载身份
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(
                deviceId: keys.deviceId,
                ed25519Pub: keys.ed25519Pub,
                ecdhPub: keys.ecdhPub
            )
        }

        // 启动网络监测(定期轮询)
        startNetworkMonitoring()
    }

    deinit {
        networkTimer?.invalidate()
        networkTask?.cancel()
    }

    // MARK: - Auth Management
    func saveAuth(token: String, sessionId: String, userId: Int, handle: String?) {
        self.authToken = token
        self.sessionId = sessionId
        self.userId = userId
        self.userHandle = handle
        try? KeychainStore.save(Data(token.utf8), account: "lmh.auth.token")
        try? KeychainStore.save(Data(sessionId.utf8), account: "lmh.auth.session")
        
        // 加载身份
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(
                deviceId: keys.deviceId,
                ed25519Pub: keys.ed25519Pub,
                ecdhPub: keys.ecdhPub
            )
        }
    }

    func logout() {
        authToken = nil
        sessionId = nil
        userId = nil
        userHandle = nil
        identity = nil
        KeychainStore.delete(account: "lmh.auth.token")
        KeychainStore.delete(account: "lmh.auth.session")
    }

    var isLoggedIn: Bool { authToken != nil }

    // MARK: - Network Monitoring
    private func startNetworkMonitoring() {
        // 定期轮询检查网络
        networkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkConnection()
            }
        }
    }

    private func checkConnection() async {
        do {
            struct HealthResult: Decodable {
                let ok: Bool
            }
            let _: HealthResult = try await APIClient.request("/health")
            if !isConnected {
                isConnected = true
                connectionStatus = .connected
            }
        } catch {
            if isConnected {
                isConnected = false
                connectionStatus = .disconnected
            }
        }
    }
}
