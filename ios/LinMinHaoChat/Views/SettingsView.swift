import SwiftUI

/// 设置页:隐私模式(强制,不可关闭)+ 服务器信息 + 关于
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("隐私模式")
                    Spacer()
                    Text("永久开启")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("隐私模式没有关闭按钮、没有设置开关:聊天界面不显示水印,消息端到端加密,服务器只保存密文,私钥仅存本机 Keychain。")
            }

            Section("隐私模式详情") {
                Text(PrivacyMode.statement)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("后端", value: "linminhao.top")
                LabeledContent("连接方式", value: "App 自动连接")
                LabeledContent("存储", value: "仅加密密文")
            } header: {
                Text("服务器")
            } footer: {
                Text("用户不需要知道服务器地址 —— App 内部自动处理(产品定位第五条)。")
            }

            if appState.isLoggedIn {
                Section {
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("客户端", value: "原生 iOS(SwiftUI + CryptoKit)")
            }
        }
        .navigationTitle("设置")
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
