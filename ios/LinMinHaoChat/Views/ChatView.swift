import SwiftUI

/// 聊天界面 —— 强制隐私模式:
/// - 不显示任何水印
/// - 本地解密后展示,服务器只有密文
/// - 进入后台由 RootView 盖隐私模糊层
struct ChatView: View {
    let session: TempRoomSession

    @StateObject private var viewModel: TempChatViewModel
    @State private var inputText = ""
    @State private var showShareSheet = false
    @State private var didAutoShare = false
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
                Button {
                    showShareSheet = true
                } label: {
                    Label("分享链接", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // 消息列表:为空时给创建者显示醒目的分享邀请卡片
            if viewModel.messages.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    Text("把链接发给朋友,加入加密聊天")
                        .font(.headline)
                    Text(shareURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 20)
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = shareURL
                        } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)

                        ShareLink(item: shareURL) {
                            Label("发送", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 40)
            } else {
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
        .onAppear {
            // 创建者进入房间后自动弹出分享面板,方便立即把链接发给朋友
            guard session.isCreator, !didAutoShare else { return }
            didAutoShare = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showShareSheet = true
            }
        }
        .onDisappear { viewModel.leave() }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(link: shareURL)
        }
    }

    private var shareURL: String {
        SessionKeyUtil.shareUrl(roomId: session.roomId, key: session.sessionKey)
    }
}

/// 分享链接面板:显示完整链接 + 复制 + 系统分享
struct ShareSheetView: View {
    let link: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("把链接发给朋友,加入加密聊天")
                .font(.headline)
            Text(link)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = link
                    dismiss()
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                ShareLink(item: link) {
                    Label("发送", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
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
