import Foundation

/// 全局应用状态
@MainActor
final class AppState: ObservableObject {
    /// 进入后台标志(触发隐私模糊层)
    @Published var isBackgrounded = false

    /// 账号会话(登录后设置;账号聊天下一阶段接线)
    @Published var authToken: String?
    @Published var sessionId: String?
    @Published var userId: Int?
    @Published var userHandle: String?

    /// 当前是否有账号登录态(Keychain 中持久化 token)
    init() {
        if let tokenData = KeychainStore.load(account: "lmh.auth.token") {
            authToken = String(data: tokenData, encoding: .utf8)
        }
    }

    var isLoggedIn: Bool { authToken != nil }

    func saveAuth(token: String, sessionId: String, userId: Int, handle: String?) {
        self.authToken = token
        self.sessionId = sessionId
        self.userId = userId
        self.userHandle = handle
        try? KeychainStore.save(Data(token.utf8), account: "lmh.auth.token")
        try? KeychainStore.save(Data(sessionId.utf8), account: "lmh.auth.session")
    }

    func logout() {
        authToken = nil
        sessionId = nil
        userId = nil
        userHandle = nil
        KeychainStore.delete(account: "lmh.auth.token")
        KeychainStore.delete(account: "lmh.auth.session")
    }
}
