import SwiftUI

// MARK: - 账号聊天视图

struct ChatView: View {
    let session: ChatRoomSession
    
    @StateObject private var viewModel: ChatRoomViewModel
    @State private var inputText = ""
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool
    
    init(session: ChatRoomSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: ChatRoomViewModel(
            roomId: session.roomId,
            token: session.token,
            identity: session.identity
        ))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 状态栏
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            
            Divider()
            
            // 消息列表
            if viewModel.messages.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    Text("端到端加密会话已建立")
                        .font(.headline)
                    Text("只有成员能读取消息内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
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
        .onDisappear { viewModel.leave() }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: viewModel.errorMessage) { _, msg in
            if let msg = msg, !msg.isEmpty {
                errorMessage = msg
                viewModel.errorMessage = nil
            }
        }
    }
}

// MARK: - 消息气泡

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
                
                if let att = msg.att {
                    attachmentView(att)
                } else {
                    Text(msg.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            msg.mine ? Color.accentColor.opacity(0.9) : Color(.systemGray6),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .foregroundStyle(msg.mine ? .white : .primary)
                        .textSelection(.enabled)
                }
                
                HStack(spacing: 4) {
                    Text(TimeUtil.formatTime(msg.ts))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !msg.mine { Spacer(minLength: 60) }
        }
    }
    
    private func attachmentView(_ att: DecryptedMsg.AttachmentInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                Text(att.name)
                    .font(.caption)
                Spacer()
                Text("\(att.size > 1024 ? "\(Int(att.size/1024))KB" : "\(att.size)B")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.primary)
    }
}
