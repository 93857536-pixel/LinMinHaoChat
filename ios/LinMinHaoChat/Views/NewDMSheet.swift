import SwiftUI

/// 新建私聊 sheet —— 从旧 ChatListView 迁出的 ECDH 密钥交换 + 建房逻辑,
/// ChatsTab「+」与 ContactsTab 共用。核心安全逻辑(IdentityCrypto/KeysAPI)原样保留。
struct NewDMSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var peerIdInput: String
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// 创建成功回调(传回 roomId + 本地显示名),由宿主决定是否跳转
    let onCreated: (String, String) -> Void

    init(prefillUserId: String = "", onCreated: @escaping (String, String) -> Void) {
        _peerIdInput = State(initialValue: prefillUserId)
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("对方用户 ID")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("输入数字用户 ID", text: $peerIdInput)
                        .keyboardType(.numberPad)
                        .lmhInput()
                }
                .padding(.horizontal, 20)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Button {
                    Task { await createDM() }
                } label: {
                    if isCreating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("发起加密私聊")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(peerIdInput.isEmpty || !peerIdInput.allSatisfy(\.isNumber) || isCreating)
                .padding(.horizontal, 20)

                Text("端到端加密:会话密钥在你的设备与对方设备间协商,服务器只存密文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("新建私聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func createDM() async {
        errorMessage = nil
        isCreating = true
        defer { isCreating = false }
        guard let peerId = Int(peerIdInput) else {
            errorMessage = "请输入有效的用户 ID"
            return
        }
        guard peerId != (appState.userId ?? 0) else {
            errorMessage = "不能和自己创建私聊"
            return
        }
        guard let token = appState.authToken else {
            errorMessage = "请先登录"
            return
        }
        guard let myIdentity = try? IdentityStore.load() else {
            errorMessage = "身份密钥缺失"
            return
        }
        do {
            // 1. 拉对方设备公钥
            let peerKeys = try await KeysAPI.getUserKeys(peerId, token: token)
            guard !peerKeys.devices.isEmpty else {
                errorMessage = "对方还没有上传公钥(对方需先登录一次)"
                return
            }
            // 2. 生成交换密钥 + 双向包装
            let sessionKey = SessionKeyUtil.generate()
            var wrappedKeys: [WrappedKeyEntry] = []
            wrappedKeys.append(WrappedKeyEntry(
                userId: appState.userId ?? 0,
                deviceId: myIdentity.deviceId,
                wrappedKey: try IdentityCrypto.wrapSessionKey(
                    sessionKey: sessionKey,
                    peerEcdhPubB64: myIdentity.ecdhPub,
                    myKeys: myIdentity
                )
            ))
            for device in peerKeys.devices {
                wrappedKeys.append(WrappedKeyEntry(
                    userId: peerId,
                    deviceId: device.device_id,
                    wrappedKey: try IdentityCrypto.wrapSessionKey(
                        sessionKey: sessionKey,
                        peerEcdhPubB64: device.ecdh_pub,
                        myKeys: myIdentity
                    )
                ))
            }
            // 3. 建房
            let result = try await ChatAPI.createRoom(
                type: "dm",
                memberIds: [peerId],
                nameEnc: nil,
                wrappedKeys: wrappedKeys,
                token: token
            )
            // 4. 本地显示名(服务器 nameEnc 是密文,本地缓存明文标签,不上传)
            let name = "账号 \(peerId)"
            UserDefaults.standard.set(name, forKey: "lmh.room.label.\(result.room.id)")
            dismiss()
            onCreated(result.room.id, name)
        } catch {
            errorMessage = "创建失败:\(error.localizedDescription)"
        }
    }
}
