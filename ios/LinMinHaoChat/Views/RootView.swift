import SwiftUI

/// 根视图:导航容器 + 后台隐私模糊层
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .overlay {
            if appState.isBackgrounded {
                PrivacyBlurView()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: appState.isBackgrounded)
            }
        }
    }
}
