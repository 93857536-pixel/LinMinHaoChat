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
    /// 我的头像版本号(服务端 avatarUpdatedAt;nil = 没有头像)
    @Published var avatarUpdatedAt: Int64?
    /// 已绑定的手机号掩码(如 139****8888)
    @Published var phoneMasked: String?
    /// 已绑定的邮箱掩码(如 l***@example.com)
    @Published var emailMasked: String?

    // MARK: 实名认证状态(none/verified/mismatch/no_record)
    @Published var realnameStatus: String = "none"
    @Published var realnameVerified: Bool = false
    @Published var realnameNameMasked: String?
    @Published var realnameVerifiedAt: Int64?

    /// 当前设备身份
    @Published var identity: DeviceIdentity?

    /// 网络状态
    @Published var isConnected: Bool = true
    @Published var connectionStatus: ConnectionStatus = .connected

    /// 是否 Demo 模式(Debug only;UserDefaults 旗或启动参数 -lmhDemoMode)
    var isDemoMode: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: ShotKeys.demo)
            || CommandLine.arguments.contains("-lmhDemoMode")
        #else
        return false
        #endif
    }

    enum ConnectionStatus: String {
        case disconnected = "网络断开"
        case reconnecting = "正在重连…"
        case connected = "已连接"
    }

    /// 网络监测定时器
    private var networkTimer: Timer?
    private var networkTask: Task<Void, Never>?
    /// 有未读的房间数(用于角标)
    @Published var unreadRoomCount = 0

    /// 全部房间的总未读数(sum of all room.unread)
    var unreadTotalRooms: Int { unreadRoomCount }

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
        static let avatarUpdatedAt = "lmh.auth.avatarUpdatedAt"
        static let rnStatus = "lmh.auth.rnStatus"
        static let rnVerified = "lmh.auth.rnVerified"
        static let rnNameMasked = "lmh.auth.rnNameMasked"
        static let rnVerifiedAt = "lmh.auth.rnVerifiedAt"
        static let phoneMasked = "lmh.auth.phoneMasked"
        static let emailMasked = "lmh.auth.emailMasked"
    }

    /// 截图验收旗(外部用 simctl spawn defaults write 注入)
    enum ShotKeys {
        static let demo = "lmh.shot.demo"
        static let tab = "lmh.shot.tab"
        static let room = "lmh.shot.room"
        static let keyExport = "lmh.shot.keyexport"
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
        let d = UserDefaults.standard
        if d.object(forKey: ProfileKeys.userId) != nil {
            userId = d.integer(forKey: ProfileKeys.userId)
        }
        userHandle = d.string(forKey: ProfileKeys.handle)
        userNickname = d.string(forKey: ProfileKeys.nickname)
        if d.object(forKey: ProfileKeys.createdAt) != nil {
            userCreatedAt = d.object(forKey: ProfileKeys.createdAt) as? Int64
        }
        if d.object(forKey: ProfileKeys.avatarUpdatedAt) != nil {
            avatarUpdatedAt = d.object(forKey: ProfileKeys.avatarUpdatedAt) as? Int64
        }
        realnameStatus = d.string(forKey: ProfileKeys.rnStatus) ?? "none"
        realnameVerified = d.bool(forKey: ProfileKeys.rnVerified)
        realnameNameMasked = d.string(forKey: ProfileKeys.rnNameMasked)
        if d.object(forKey: ProfileKeys.rnVerifiedAt) != nil {
            realnameVerifiedAt = d.object(forKey: ProfileKeys.rnVerifiedAt) as? Int64
        }
        phoneMasked = d.string(forKey: ProfileKeys.phoneMasked)
        emailMasked = d.string(forKey: ProfileKeys.emailMasked)

        // 尝试加载身份
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(deviceId: keys.deviceId, ed25519Pub: keys.ed25519Pub, ecdhPub: keys.ecdhPub)
        }

        // 启动网络监测(定期轮询)
        startNetworkMonitoring()

        // Demo 模式:纯本地硬编码数据,不依赖服务器
        if isDemoMode {
            print("[AppState] DEMO MODE: injecting seed data")
            authToken = "demo-jwt"
            sessionId = "demo-session"
            userId = 9999
            userHandle = "demo_user"
            userNickname = "演示用户"
            phoneMasked = "138****0001"
            emailMasked = "d***@example.com"
            realnameVerified = true
            realnameNameMasked = "张***"
            realnameStatus = "verified"
            // 确保 identity 非空
            if identity == nil {
                identity = DeviceIdentity(deviceId: "demo-device", ed25519Pub: "", ecdhPub: "")
            }
            // 持久化到 UserDefaults(保证列表页能读到登录态)
            let d = UserDefaults.standard
            d.set(userId, forKey: ProfileKeys.userId)
            d.set(userHandle!, forKey: ProfileKeys.handle)
            d.set(userNickname!, forKey: ProfileKeys.nickname)
            d.set(phoneMasked ?? "", forKey: ProfileKeys.phoneMasked)
            d.set(emailMasked ?? "", forKey: ProfileKeys.emailMasked)
            d.set("verified", forKey: ProfileKeys.rnStatus)
            d.set(true, forKey: ProfileKeys.rnVerified)
            d.set(realnameNameMasked ?? "", forKey: ProfileKeys.rnNameMasked)
            // demo 房间标签
            d.set("截图验收私聊", forKey: "lmh.room.label.demo-room-chat")
            d.set("验收群聊", forKey: "lmh.room.label.demo-room-group")
            d.set("搜索测试会话", forKey: "lmh.room.label.demo-room-search")
        }

        // 有登录态则后台刷新资料(demo 模式跳过,不发网络请求)
        if authToken != nil, !isDemoMode {
            Task { await refreshProfile() }
        }


    }

    deinit {
        networkTimer?.invalidate()
        networkTask?.cancel()
    }

    // MARK: - Auth Management
    func saveAuth(token: String, sessionId: String, userId: Int, handle: String?, nickname: String? = nil,
                  phoneMasked: String? = nil, emailMasked: String? = nil) {
        self.authToken = token
        self.sessionId = sessionId
        self.userId = userId
        self.userHandle = handle
        self.userNickname = nickname ?? handle
        applyCredentialMasks(phone: phoneMasked, email: emailMasked)
        try? KeychainStore.save(Data(token.utf8), account: "lmh.auth.token")
        try? KeychainStore.save(Data(sessionId.utf8), account: "lmh.auth.session")

        let d = UserDefaults.standard
        d.set(userId, forKey: ProfileKeys.userId)
        if let handle { d.set(handle, forKey: ProfileKeys.handle) }
        if let nn = self.userNickname { d.set(nn, forKey: ProfileKeys.nickname) }

        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(
                deviceId: keys.deviceId,
                ed25519Pub: keys.ed25519Pub,
                ecdhPub: keys.ecdhPub
            )
        }

        Task { await refreshProfile() }
    }

    /// 重新从 Keychain 载入身份(导入身份包后刷新内存缓存)
    func reloadIdentity() {
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(
                deviceId: keys.deviceId,
                ed25519Pub: keys.ed25519Pub,
                ecdhPub: keys.ecdhPub
            )
        }
    }

    /// 应用登录凭据掩码(手机号/邮箱),非 nil 时覆盖并持久化
    func applyCredentialMasks(phone: String?, email: String?) {
        if let p = phone { phoneMasked = p }
        if let e = email { emailMasked = e }
        let d = UserDefaults.standard
        if let p = phoneMasked { d.set(p, forKey: ProfileKeys.phoneMasked) }
        if let e = emailMasked { d.set(e, forKey: ProfileKeys.emailMasked) }
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
                    let hasAvatar: Bool?
                    let avatarUpdatedAt: Int64?
                    let realnameStatus: String?
                    let realnameVerified: Bool?
                    let realnameNameMasked: String?
                    let realnameVerifiedAt: Int64?
                    let phoneMasked: String?
                    let emailMasked: String?
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
            applyAvatar(updatedAt: me.user.hasAvatar == true ? me.user.avatarUpdatedAt : nil)
            phoneMasked = me.user.phoneMasked
            emailMasked = me.user.emailMasked
            if let pm = phoneMasked { d.set(pm, forKey: ProfileKeys.phoneMasked) } else { d.removeObject(forKey: ProfileKeys.phoneMasked) }
            if let em = emailMasked { d.set(em, forKey: ProfileKeys.emailMasked) } else { d.removeObject(forKey: ProfileKeys.emailMasked) }
            applyRealname(status: me.user.realnameStatus ?? "none",
                          verified: me.user.realnameVerified ?? false,
                          nameMasked: me.user.realnameNameMasked,
                          verifiedAt: me.user.realnameVerifiedAt)
        } catch {
            print("[AppState] refreshProfile failed: \(error.localizedDescription)")
        }
    }

    /// 应用实名状态(服务端返回 / 认证成功后调用),并持久化
    func applyRealname(status: String, verified: Bool, nameMasked: String?, verifiedAt: Int64?) {
        realnameStatus = status
        realnameVerified = verified
        realnameNameMasked = nameMasked
        realnameVerifiedAt = verifiedAt
        let d = UserDefaults.standard
        d.set(status, forKey: ProfileKeys.rnStatus)
        d.set(verified, forKey: ProfileKeys.rnVerified)
        if let nameMasked { d.set(nameMasked, forKey: ProfileKeys.rnNameMasked) } else { d.removeObject(forKey: ProfileKeys.rnNameMasked) }
        if let verifiedAt { d.set(verifiedAt, forKey: ProfileKeys.rnVerifiedAt) } else { d.removeObject(forKey: ProfileKeys.rnVerifiedAt) }
    }

    /// 应用头像版本号(上传成功 / 拉取资料 / 删除头像时调用),并持久化
    func applyAvatar(updatedAt: Int64?) {
        avatarUpdatedAt = updatedAt
        let d = UserDefaults.standard
        if let updatedAt { d.set(updatedAt, forKey: ProfileKeys.avatarUpdatedAt) }
        else { d.removeObject(forKey: ProfileKeys.avatarUpdatedAt) }
    }

    func logout() {
        authToken = nil
        sessionId = nil
        userId = nil
        userHandle = nil
        userNickname = nil
        userCreatedAt = nil
        avatarUpdatedAt = nil
        phoneMasked = nil
        emailMasked = nil
        realnameStatus = "none"
        realnameVerified = false
        realnameNameMasked = nil
        realnameVerifiedAt = nil
        identity = nil
        KeychainStore.delete(account: "lmh.auth.token")
        KeychainStore.delete(account: "lmh.auth.session")
        let d = UserDefaults.standard
        [ProfileKeys.userId, ProfileKeys.handle, ProfileKeys.nickname, ProfileKeys.createdAt,
         ProfileKeys.avatarUpdatedAt, ProfileKeys.phoneMasked, ProfileKeys.emailMasked,
         ProfileKeys.rnStatus, ProfileKeys.rnVerified, ProfileKeys.rnNameMasked, ProfileKeys.rnVerifiedAt]
            .forEach { d.removeObject(forKey: $0) }
    }

    var isLoggedIn: Bool { authToken != nil }

    // MARK: - Network Monitoring
    private func startNetworkMonitoring() {
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
