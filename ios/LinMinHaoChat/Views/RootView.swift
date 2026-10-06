import SwiftUI

/// 根视图:导航容器 + 后台隐私模糊层 + 邀请深链路由
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var inviteSession: InviteSession

    var body: some View {
        NavigationStack {
            HomeView()
                .navigationDestination(isPresented: bindingHasPendingInvite) {
                    if let req = inviteSession.pending {
                        InviteChatView(inviteId: req.inviteId, sessionKeyB64url: req.sessionKeyB64url)
                    }
                }
        }
        .overlay {
            if appState.isBackgrounded {
                PrivacyBlurView()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: appState.isBackgrounded)
            }
        }
    }

    private var bindingHasPendingInvite: Binding<Bool> {
        Binding(
            get: { inviteSession.pending != nil },
            set: { if !$0 { inviteSession.pending = nil } }
        )
    }
}
