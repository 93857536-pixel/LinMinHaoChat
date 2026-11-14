import SwiftUI
import UserNotifications

@main
struct LinMinHaoChatApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var inviteSession = InviteSession()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 设置通知代理
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(inviteSession)
                .onAppear {
                    // App启动时请求通知权限
                    Task { await NotificationManager.shared.requestAuthorization() }
                }
                .onOpenURL { url in
                    // 系统打开链接:https://chat.linminhao.top/i/<id>... 或 lmhchat://invite/<id>
                    handleLink(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // iOS 隐私保护:进入后台立即盖隐私模糊层,应用切换器不泄露聊天内容
                    appState.isBackgrounded = (newPhase != .active)
                }
        }
    }

    private func handleLink(_ url: URL) {
        let jwt = AppState.shared.authToken
        let nickname = AppState.shared.displayName
        if let req = InviteLinkParser.parse(url: url, jwt: jwt, nickname: nickname) {
            inviteSession.pending = req
        }
    }
}
