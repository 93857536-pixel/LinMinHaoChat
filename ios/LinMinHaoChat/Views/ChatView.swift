import SwiftUI

/// 聊天界面 —— 强制隐私模式:
/// - 不显示任何水印
/// - 本地解密后展示,服务器只有密文
/// - 进入后台由 RootView 盖隐私模糊层
struct ChatView: View {
    let session: TempRoomSession

    @StateObject private var viewModel: TempChatViewModel
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    init(session: TempRoomSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: TempChatViewModel(roomId: session.roomId, sessionKey: session.sessionKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 状态栏(顶部)
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(viewModel.statusText)
                    .font(.caption)
                Spacer()
                if let ips = viewModel.onlineIps {
                    Text("\(ips) 个IP在线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.messages) { msg in
                            MessageBubbleView(msg: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // 输入栏
            HStack(alignment: .bottom, spacing: 10) {
                TextField("加密消息", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    let text = inputText
                    inputText = ""
                    Task { await viewModel.send(text) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18))
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("加密聊天")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.leave() }
    }

    private var shareURL: String {
        SessionKeyUtil.shareUrl(roomId: session.roomId, key: session.sessionKey)
    }
}

/// 单条消息气泡(无水印设计;自己靠右、他人靠左)
struct MessageBubbleView: View {
    let msg: DecryptedMsg

    var body: some View {
        HStack {
            if msg.mine { Spacer(minLength: 60) }
            VStack(alignment: msg.mine ? .trailing : .leading, spacing: 3) {
                if !msg.mine {
                    Text(msg.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(msg.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        msg.mine ? Color.accentColor.opacity(0.9) : Color(.systemGray6),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .foregroundStyle(msg.mine ? .white : .primary)
                    .textSelection(.enabled)
                Text(TimeUtil.formatTime(msg.ts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !msg.mine { Spacer(minLength: 60) }
        }
    }
}
