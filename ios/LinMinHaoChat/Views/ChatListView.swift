import SwiftUI
import Network

// MARK: - 账号聊天根视图(会话列表)

struct ChatListView: View {
    @StateObject private var viewModel = ChatListViewModel()
    @State private var showCreateDM = false
    @State private var peerIdInput = ""
    @State private var errorMessage: String?
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.rooms.isEmpty {
                    contentEmpty
                } else {
                    contentList
                }
            }
            .navigationTitle("账号聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("新建私聊") {
                        showCreateDM = true
                    }
                }
            }
            .task { await viewModel.loadRooms() }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showCreateDM) {
                createDMSheet
            }
        }
    }
    
    private var contentEmpty: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("还没有会话")
                .font(.headline)
            Text("点击「新建私聊」输入对方用户 ID 开始加密聊天")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var contentList: some View {
        List(viewModel.rooms) { room in
            NavigationLink(value: room.id) {
                ChatView(session: ChatRoomSession(
                    id: room.id,
                    roomId: room.id,
                    token: appState.authToken ?? "",
                    identity: viewModel.identity ?? DeviceIdentity(deviceId: "", ed25519Pub: "", ecdhPub: "")
                ))
            }
        }
    }
    
    private var createDMSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("对方用户 ID(数字)", text: $peerIdInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                
                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                
                Button("创建") {
                    Task { await createDM() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(peerIdInput.isEmpty || !peerIdInput.allSatisfy(\.isNumber))
                
                Button("取消") { showCreateDM = false }
                    .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("新建私聊")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func createDM() async {
        errorMessage = nil
        guard let peerId = Int(peerIdInput) else {
            errorMessage = "请输入有效的用户 ID"
            return
        }
        guard peerId != (AppState.shared.userId ?? 0) else {
            errorMessage = "不能和自己创建私聊"
            return
        }
        guard let token = AppState.shared.authToken else {
            errorMessage = "请先登录"
            return
        }
        guard let myIdentity = try? IdentityStore.load() else {
            errorMessage = "身份密钥缺失"
            return
        }
        
        do {
            let peerKeys = try await KeysAPI.getUserKeys(peerId, token: token)
            guard !peerKeys.devices.isEmpty else {
                errorMessage = "对方还没有上传公钥(对方需先登录一次)"
                return
            }
            
            // 生成交换密钥
            let sessionKey = SessionKeyUtil.generate()
            var wrappedKeys: [WrappedKeyEntry] = []
            
            // 包装给自己
            wrappedKeys.append(WrappedKeyEntry(
                userId: AppState.shared.userId ?? 0,
                deviceId: myIdentity.deviceId,
                wrappedKey: try IdentityCrypto.wrapSessionKey(
                    sessionKey: sessionKey,
                    peerEcdhPubB64: myIdentity.ecdhPub,
                    myKeys: myIdentity
                )
            ))
            
            // 包装给对方
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
            
            // 创建房间
            let result = try await ChatAPI.createRoom(
                type: "dm",
                memberIds: [peerId],
                nameEnc: nil,
                wrappedKeys: wrappedKeys,
                token: token
            )
            showCreateDM = false
            peerIdInput = ""
            await viewModel.loadRooms()
        } catch {
            errorMessage = "创建失败:\(error.localizedDescription)"
        }
    }
}

// MARK: - 会话列表 ViewModel

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var rooms: [RoomMeta] = []
    @Published var identity: DeviceIdentity?
    
    func loadRooms() async {
        guard let token = AppState.shared.authToken else { return }
        do {
            let result = try await ChatAPI.rooms(token: token)
            rooms = result.rooms.sorted { $0.createdAt > $1.createdAt }
        } catch {
            rooms = []
        }
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(
                deviceId: keys.deviceId,
                ed25519Pub: keys.ed25519Pub,
                ecdhPub: keys.ecdhPub
            )
        }
    }
    
    func refresh() async {
        await loadRooms()
    }
}
