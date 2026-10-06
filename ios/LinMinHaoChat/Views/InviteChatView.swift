import SwiftUI

/// 邀请聊天视图 —— 与 web InviteChat.tsx 对齐:
/// 验证码校验 → 加入(游客或账号)→ 拉历史/WS 实时 → 发消息
struct InviteChatView: View {
    let inviteId: String
    let sessionKeyB64url: String?

    @StateObject private var viewModel: InviteChatViewModel
    @State private var codeInput = ""
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    init(inviteId: String, sessionKeyB64url: String? = nil) {
        self.inviteId = inviteId
        self.sessionKeyB64url = sessionKeyB64url
        _viewModel = StateObject(wrappedValue: InviteChatViewModel(
            inviteId: inviteId,
            sessionKeyB64url: sessionKeyB64url,
            accountToken: AppState.shared.authToken
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.status {
            case .loading:
                loadingView
            case .needCode:
                codeView
            case .chat:
                chatView
            case .error(let msg):
                errorView(msg)
            }
        }
        .navigationTitle("邀请聊天")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.leave() }
        .alert("错误", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("确定") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - 子视图
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.5)
            Text("正在验证邀请…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var codeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 48)).foregroundStyle(Color.accentColor)
            Text("邀请房间需要 6 位验证码").font(.headline)
            TextField("验证码", text: $codeInput)
                .lmhInput().keyboardType(.numberPad)
                .autocorrectionDisabled(true)
            Button("加入房间") {
                let code = codeInput
                codeInput = ""
                Task { await viewModel.join(code: code) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!codeInput.allSatisfy(\.isNumber) || codeInput.count < 6)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            // 状态栏
            HStack(spacing: 6) {
                Circle().fill(viewModel.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(viewModel.statusText).font(.caption)
                Spacer()
                if let ips = viewModel.onlineIps {
                    Text("\(ips) 个IP在线").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)

            Divider()

            // 消息列表
            if viewModel.messages.isEmpty {
                emptyMessagesView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.messages) { msg in
                                MessageBubbleView(
                                    msg: msg,
                                    onCopy: { UIPasteboard.general.string = msg.text },
                                    onDelete: nil
                                ).id(msg.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
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
                    .lineLimit(1...5).focused($inputFocused)
                    .lmhChatInputBubble()

                Button {
                    let text = inputText
                    inputText = ""
                    Task { await viewModel.send(text) }
                } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 18))
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var emptyMessagesView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill").font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("邀请加密会话已建立").font(.headline)
            Text("只有持有链接密钥和验证码的人能读取消息").font(.caption)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            if !viewModel.displaySelf.isEmpty {
                Text("你以「\(viewModel.displaySelf)」身份加入").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 40)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50)).foregroundStyle(.red)
            Text(msg).font(.headline).multilineTextAlignment(.center).padding(.horizontal)
            Button("返回") { viewModel.errorMessage = nil; viewModel.status = .loading }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
