import SwiftUI

/// 隐私模糊层:App 进入后台时覆盖全屏,
/// 防止应用切换器/截屏泄露聊天内容(iOS 隐私保护,产品定位第三条)。
struct PrivacyBlurView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                Text("LinMinHao Chat")
                    .font(.headline)
                Text("隐私模式:回到 App 继续")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }
}
