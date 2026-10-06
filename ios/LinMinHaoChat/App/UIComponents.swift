import SwiftUI

// MARK: - 统一输入框外观
// 全站输入框共用:卡片式背景(与登录页一致,深色模式无突兀灰边),
// 替代原生 .roundedBorder 灰描边与 systemGray6 浅灰块。

extension View {
    /// 表单输入框统一样式(卡片背景 + 圆角,深色友好)
    func lmhInput() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 聊天输入栏气泡样式(圆角胶囊,与表单卡片同底色)
    func lmhChatInputBubble() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 38)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
