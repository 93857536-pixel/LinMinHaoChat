import SwiftUI

@main
struct LinMinHaoChatApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var inviteSession = InviteSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(inviteSession)
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
        let nickname = AppState.shared.userHandle
        if let req = InviteLinkParser.parse(url: url, jwt: jwt, nickname: nickname) {
            inviteSession.pending = req
        }
    }
}
