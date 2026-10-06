import SwiftUI

// MARK: - 邀请聊天视图

struct InviteChatView: View {
    let inviteId: String
    
    @StateObject private var viewModel: InviteChatViewModel
    @State private var codeInput = ""
    @State private var errorMessage: String?
    
    init(inviteId: String) {
        self.inviteId = inviteId
        _viewModel = StateObject(wrappedValue: InviteChatViewModel(inviteId: inviteId))
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // 状态区域
            if case .loading = viewModel.status {
                contentLoading
            } else if case .error(let msg) = viewModel.status {
                contentError(msg: msg)
            } else if case .roomInfo(let info) = viewModel.status {
                contentRoomInfo(info: info)
            } else if case .connected = viewModel.status {
                contentConnected
            }
            
            // 密码输入(如需)
            if viewModel.needsCode {
                VStack(spacing: 8) {
                    Text("请输入房间密码")
                        .font(.headline)
                    
                    SecureField("房间密码", text: $codeInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    
                    Button("加入") {
                        Task { await viewModel.join(code: codeInput) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(codeInput.isEmpty)
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("邀请加入")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.verify() }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private var contentLoading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在验证邀请…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func contentError(msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.red)
            Text(msg)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("返回") {
                viewModel.showError(error: nil)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func contentRoomInfo(info: InviteChatViewModel.RoomInfo) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.accentColor)
            
            Text(info.roomName.isEmpty ? "加密房间" : info.roomName)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("由 \(info.createdByLabel) 创建于 \(TimeUtil.formatRelative(info.createdAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if info.expiresInSec > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("有效期至 \(TimeUtil.formatRelative(info.expiresAt))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
    
    private var contentConnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)
            Text("已加入房间")
                .font(.headline)
            Text("你正在使用邀请链接加入的加密房间")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
