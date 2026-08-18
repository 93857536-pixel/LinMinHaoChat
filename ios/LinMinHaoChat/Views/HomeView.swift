import SwiftUI

/// 首页 —— 用户打开 App 直接看到:LinMinHao Chat + 临时聊天 / 登录注册 / 设置
struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color.accentColor, .indigo],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
            }
            .shadow(color: .accentColor.opacity(0.35), radius: 16, y: 8)

            Text("LinMinHao Chat")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            Text("端到端加密 · 强制隐私模式")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Spacer()

            // 入口
            VStack(spacing: 14) {
                NavigationLink {
                    TempRoomView()
                } label: {
                    Label("临时聊天", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                NavigationLink {
                    LoginView()
                } label: {
                    Label(appState.isLoggedIn ? "账号(已登录)" : "登录 / 注册", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                Text("隐私模式永久开启 · 服务器仅存密文")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
        .navigationTitle("LinMinHao Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}
