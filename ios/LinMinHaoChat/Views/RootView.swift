import SwiftUI

/// 根视图:类微信 IM 交互 —— 底部 4 Tab(聊天 / 通讯录 / 发现 / 我的),
/// 默认落在「聊天」列表页;邀请深链全局浮层;后台隐私模糊层。
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var inviteSession: InviteSession
    @State private var selectedTab: AppTab = .chats
    @State private var activeInvite: InviteSession.InviteRequest?

    enum AppTab: Hashable {
        case chats, contacts, discover, me
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatsTab()
                .environmentObject(appState)
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(AppTab.chats)

            ContactsTab()
                .environmentObject(appState)
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
                .tag(AppTab.contacts)

            DiscoverTab()
                .environmentObject(appState)
                .tabItem {
                    Label("发现", systemImage: "safari")
                }
                .tag(AppTab.discover)

            MeTab()
                .environmentObject(appState)
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(AppTab.me)
        }
        .tint(.blue)
        .fullScreenCover(item: $activeInvite) { req in
            InviteChatView(inviteId: req.inviteId, sessionKeyB64url: req.sessionKeyB64url)
                .environmentObject(appState)
                .onDisappear { activeInvite = nil }
        }
        .onChange(of: inviteSession.pending) { _, req in
            // App.onOpenURL / 外部入口写入 pending → 全屏盖层进入邀请聊天
            if let req {
                inviteSession.pending = nil
                activeInvite = req
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
}
