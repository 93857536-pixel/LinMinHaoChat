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
    /// 规范账号 ID(注册时自动生成,如 202210216pm.A;不可改)
    @Published var userHandle: String?
    /// 昵称/账号名称(可改,默认为账号 ID)
    @Published var userNickname: String?
    /// 注册时间(毫秒)
    @Published var userCreatedAt: Int64?

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
    @Published var chatListVersion = 0   // 进入聊天后自增,通知列表刷新未读/预览

    /// 界面显示用名称:昵称 → 账号 ID → 兜底
    var displayName: String { userNickname ?? userHandle ?? "已登录" }

    // UserDefaults 持久化键(与 Keychain 中的 token/session 互补)
    private enum ProfileKeys {
        static let userId = "lmh.auth.userId"
        static let handle = "lmh.auth.handle"
        static let nickname = "lmh.auth.nickname"
        static let createdAt = "lmh.auth.createdAt"
    }

    init() {
        // 恢复认证信息
        if let tokenData = KeychainStore.load(account: "lmh.auth.token") {
            authToken = String(data: tokenData, encoding: .utf8)
        }
        if let sessionData = KeychainStore.load(account: "lmh.auth.session") {
            sessionId = String(data: sessionData, encoding: .utf8)
        }

        // 恢复账号资料(userId / 账号 ID / 昵称 / 注册时间)
        // 修复:此前只恢复 token,退出 App 再进入时用户名与账号 ID 显示为空
        let d = UserDefaults.standard
        if d.object(forKey: ProfileKeys.userId) != nil {
            userId = d.integer(forKey: ProfileKeys.userId)
        }
        userHandle = d.string(forKey: ProfileKeys.handle)
        userNickname = d.string(forKey: ProfileKeys.nickname)
        if d.object(forKey: ProfileKeys.createdAt) != nil {
            userCreatedAt = d.object(forKey: ProfileKeys.createdAt) as? Int64
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

        // 有登录态则后台刷新资料(兼容旧版本升级/换设备后本地无资料的场景)
        if authToken != nil {
            Task { await refreshProfile() }
        }
    }

    deinit {
        networkTimer?.invalidate()
        networkTask?.cancel()
    }

    // MARK: - Auth Management
    func saveAuth(token: String, sessionId: String, userId: Int, handle: String?, nickname: String? = nil) {
        self.authToken = token
        self.sessionId = sessionId
        self.userId = userId
        self.userHandle = handle
        self.userNickname = nickname ?? handle
        try? KeychainStore.save(Data(token.utf8), account: "lmh.auth.token")
        try? KeychainStore.save(Data(sessionId.utf8), account: "lmh.auth.session")

        // 持久化账号资料(重启 App 后可直接显示,无需等网络)
        let d = UserDefaults.standard
        d.set(userId, forKey: ProfileKeys.userId)
        if let handle { d.set(handle, forKey: ProfileKeys.handle) }
        if let nn = self.userNickname { d.set(nn, forKey: ProfileKeys.nickname) }

        // 加载身份
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(
                deviceId: keys.deviceId,
                ed25519Pub: keys.ed25519Pub,
                ecdhPub: keys.ecdhPub
            )
        }
    }

    /// 后台刷新账号资料(启动时/从服务端确认最新昵称)
    func refreshProfile() async {
        guard let token = authToken else { return }
        do {
            struct MeResult: Decodable {
                struct User: Decodable {
                    let id: Int
                    let handle: String?
                    let nickname: String?
                    let createdAt: Int64?
                }
                let ok: Bool
                let user: User
            }
            let me: MeResult = try await APIClient.request("/auth/me", token: token)
            userId = me.user.id
            userHandle = me.user.handle
            userNickname = me.user.nickname ?? me.user.handle
            userCreatedAt = me.user.createdAt
            let d = UserDefaults.standard
            d.set(me.user.id, forKey: ProfileKeys.userId)
            if let h = me.user.handle { d.set(h, forKey: ProfileKeys.handle) }
            if let n = userNickname { d.set(n, forKey: ProfileKeys.nickname) }
            if let ts = me.user.createdAt { d.set(ts, forKey: ProfileKeys.createdAt) }
        } catch {
            // 网络异常/令牌过期时不打断使用;本地缓存已可显示
            print("[AppState] refreshProfile failed: \(error.localizedDescription)")
        }
    }

    func logout() {
        authToken = nil
        sessionId = nil
        userId = nil
        userHandle = nil
        userNickname = nil
        userCreatedAt = nil
        identity = nil
        KeychainStore.delete(account: "lmh.auth.token")
        KeychainStore.delete(account: "lmh.auth.session")
        let d = UserDefaults.standard
        [ProfileKeys.userId, ProfileKeys.handle, ProfileKeys.nickname, ProfileKeys.createdAt]
            .forEach { d.removeObject(forKey: $0) }
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
