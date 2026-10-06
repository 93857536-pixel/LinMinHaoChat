import SwiftUI

/// 创建邀请聊天 —— 与 web Home.tsx startInvite 对齐:
/// POST /invite/create → 生成会话密钥 → 链接(#k= 密钥 fragment)+ 6 位验证码
/// 创建者本机持久化密钥,刷新/重进可恢复记录
@MainActor
final class InviteCreateViewModel: ObservableObject {
    @Published var box: (link: String, code: String)?
    @Published var isWorking = false
    @Published var errorMessage: String?

    func create() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let c: InviteAPI.CreateResult = try await InviteAPI.create()
            let key = SessionKeyUtil.generate()
            let keyB64 = SessionKeyUtil.b64url(key)
            // 创建者持久化密钥(房间 1 年有效,重进恢复记录)
            UserDefaults.standard.set(keyB64, forKey: "lmh.invite.key.\(c.roomId)")
            let link = InviteLinkParser.makeLink(
                host: AppEnvironment.host,
                inviteId: c.inviteId,
                account: false,
                keyB64: keyB64,
                roomCode: nil
            )
            box = (link, c.code)
        } catch {
            errorMessage = "创建失败:\(error.localizedDescription)"
        }
    }

    var shareText: String {
        guard let (link, code) = box else { return "" }
        return "【LinMinHao Chat 邀请】\n链接:\(link)\n验证码:\(code)\n(打开链接后输入验证码即可进入聊天,记录长期保留)"
    }
}

/// 邀请创建弹窗:链接 + 验证码 + 复制
struct InviteCreateSheet: View {
    @StateObject private var vm = InviteCreateViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let box = vm.box {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("邀请链接")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(box.link)
                                .font(.caption)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("6 位验证码")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(box.code)
                                .font(.title.bold().monospacedDigit())
                                .textSelection(.enabled)
                        }
                    }
                    .padding()

                    Text("请通过安全渠道发送链接与验证码。创建者本机已保存密钥,重进可恢复记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button {
                        UIPasteboard.general.string = vm.shareText
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "已复制" : "复制链接与验证码",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if vm.isWorking {
                    ProgressView("正在创建邀请…")
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("创建邀请聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await vm.create() }
            .alert("错误", isPresented: .constant(vm.errorMessage != nil)) {
                Button("重试") { Task { await vm.create() } }
                Button("取消") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
        }
        .onAppear { copied = false }
    }
}
