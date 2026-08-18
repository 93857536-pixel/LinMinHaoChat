import SwiftUI

@main
struct LinMinHaoChatApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onChange(of: scenePhase) { _, newPhase in
                    // iOS 隐私保护:进入后台立即盖隐私模糊层,应用切换器不泄露聊天内容
                    appState.isBackgrounded = (newPhase != .active)
                }
        }
    }
}
