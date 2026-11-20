import CryptoKit
import Foundation
import SwiftUI

/// 聊天列表 ViewModel —— 聚合房间列表/未读/本地预览/置顶,
/// 复用 ChatAPI(只读 API 不变),预览走本地 ChatPreviewStore(不上传)。
@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var rooms: [RoomMeta] = []
    @Published var pinnedRoomIds: Set<String> = []
    @Published var searchText = ""

    private static let pinnedKey = "lmh.chat.pinned.v1"

    var identity: DeviceIdentity?

    /// 置顶在前 + 其余按创建时间倒序(服务器无最近活动时间,createdAt 兜底)
    var sortedRooms: [RoomMeta] {
        let filtered = rooms.filter { room in
            guard !self.searchText.isEmpty else { return true }
            return self.label(for: room).localizedCaseInsensitiveContains(self.searchText)
        }
        return filtered.sorted { a, b in
            let pa = self.pinnedRoomIds.contains(a.id), pb = self.pinnedRoomIds.contains(b.id)
            if pa != pb { return pa }
            return a.createdAt > b.createdAt
        }
    }

    init() {
        if let d = UserDefaults.standard.string(forKey: Self.pinnedKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: Data(d.utf8)) {
            pinnedRoomIds = ids
        }
        if let keys = try? IdentityStore.load() {
            identity = DeviceIdentity(deviceId: keys.deviceId,
                                      ed25519Pub: keys.ed25519Pub,
                                      ecdhPub: keys.ecdhPub)
        }
    }

    func loadRooms() async {
        // Demo 模式:直接注入模拟房间,不依赖服务器
        if AppState.shared.isDemoMode {
            print("[ChatsTab] DEMO: injecting seed rooms")
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            rooms = [
                RoomMeta(id: "demo-room-chat", type: "dm", nameEnc: nil, createdAt: nowMs - 60_000, memberIds: [9999], unread: 1, lastSeq: 3),
                RoomMeta(id: "demo-room-group", type: "group", nameEnc: nil, createdAt: nowMs - 120_000, memberIds: [9999, 8888], unread: 0, lastSeq: 5),
                RoomMeta(id: "demo-room-search", type: "dm", nameEnc: nil, createdAt: nowMs - 10_000, memberIds: [9999], unread: 2, lastSeq: 1),
            ]
            return
        }
        guard let token = AppState.shared.authToken else { rooms = []; return }
        do {
            let result = try await ChatAPI.rooms(token: token)
            rooms = result.rooms.sorted { $0.createdAt > $1.createdAt }
        } catch {
            rooms = []
        }
    }

    // MARK: - 本地会话标签(服务器 nameEnc 为密文不可读,本地缓存明文;不上传)
    func label(for room: RoomMeta) -> String {
        if let stored = UserDefaults.standard.string(forKey: "lmh.room.label.\(room.id)") {
            return stored
        }
        return room.type == "dm" ? "私聊" : "群聊"
    }

    /// 列表预览:本地缓存的最后一条消息(文本+时间);无缓存时用房间创建时间占位
    func preview(for room: RoomMeta) -> (text: String, ts: Int64)? {
        if let p = ChatPreviewStore.shared.preview(room.id) {
            let prefix = p.senderLabel ?? ""
            return ((prefix.isEmpty ? "" : prefix + " ") + p.text, p.ts)
        }
        return ("新会话", room.createdAt)
    }

    // MARK: - 置顶 / 已读 / 删除(本地记录)
    func togglePinned(_ roomId: String) {
        if pinnedRoomIds.contains(roomId) { pinnedRoomIds.remove(roomId) }
        else { pinnedRoomIds.insert(roomId) }
        persistPinned()
    }

    /// 免打扰开关(走全局 RoomFlagsStore, 与通知/角标同一数据源)
    func toggleMuted(_ roomId: String) {
        RoomFlagsStore.shared.toggleMuted(roomId)
        objectWillChange.send()
    }

    func isMuted(_ roomId: String) -> Bool { RoomFlagsStore.shared.isMuted(roomId) }

    /// 本地清未读徽章(真正已读回执由进入聊天时 ChatAPI.markRead 完成)
    func markReadLocally(_ roomId: String) {
        for i in rooms.indices where rooms[i].id == roomId {
            rooms[i].unread = 0
        }
    }

    /// 删除聊天记录入口:清本地预览与标签(服务器消息保留,E2EE 历史无法客户端删除)
    func deleteChatRecords(_ roomId: String) {
        ChatPreviewStore.shared.clear(roomId)
        objectWillChange.send()
    }

    private func persistPinned() {
        if let d = try? JSONEncoder().encode(pinnedRoomIds) {
            UserDefaults.standard.set(String(data: d, encoding: .utf8) ?? "", forKey: Self.pinnedKey)
        }
    }
}

// MARK: - 聊天列表 Tab(打开 App 的默认页)

struct ChatsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = ChatListViewModel()

    @State private var showNewDM = false
    @State private var showInviteCreate = false
    @State private var showTempChat = false
    @State private var showLogin = false
    @State private var showFindFriends = false
    @State private var navPath: [String] = []

    var body: some View {
        Group {
            if appState.isLoggedIn {
                loggedInList
            } else {
                notLoggedIn
            }
        }
        .sheet(isPresented: $showNewDM) {
            NewDMSheet { _, _ in
                Task { await vm.loadRooms() }
            }
        }
        .sheet(isPresented: $showInviteCreate) {
            InviteCreateSheet()
        }
        .sheet(isPresented: $showTempChat) {
            TempRoomView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showLogin) {
            LoginView(preferRegister: false)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showFindFriends) {
            FindFriendsSheet()
                .environmentObject(appState)
        }
    }

    // MARK: 已登录:列表
    private var loggedInList: some View {
        NavigationStack {
            Group {
                if vm.sortedRooms.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(vm.sortedRooms) { room in
                            row(room)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("聊天")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $vm.searchText, prompt: "搜索联系人")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showNewDM = true
                        } label: {
                            Label("发起聊天", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        Button {
                            showFindFriends = true
                        } label: {
                            Label("查找好友", systemImage: "person.badge.plus")
                        }
                        Button {
                            showInviteCreate = true
                        } label: {
                            Label("创建邀请聊天", systemImage: "envelope.badge")
                        }
                        Button {
                            showTempChat = true
                        } label: {
                            Label("临时聊天", systemImage: "bolt.fill")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await vm.loadRooms() }
            .refreshable { await vm.loadRooms() }
            .onChange(of: appState.chatListVersion) { _ in
                // 进入过聊天/有新消息后,未读数与预览即时刷新
                Task { await vm.loadRooms() }
            }
            .navigationDestination(for: String.self) { roomId in
                ChatView(
                    session: ChatRoomSession(
                        id: roomId,
                        roomId: roomId,
                        token: appState.authToken ?? "",
                        identity: vm.identity ?? DeviceIdentity(deviceId: "", ed25519Pub: "", ecdhPub: "")
                    )
                )
                .environmentObject(appState)
                .onDisappear { appState.chatListVersion += 1 }
            }
        }
    }

    /// 单行:头像 + 名称/时间 + 预览/未读;左滑操作 + 长按菜单
    private func row(_ room: RoomMeta) -> some View {
        let label = vm.label(for: room)
        let preview = vm.preview(for: room)
        let pinned = vm.pinnedRoomIds.contains(room.id)
        let muted = vm.isMuted(room.id)

        return NavigationLink(value: room.id) {
            HStack(spacing: 12) {
                ChatAvatar(label: label, isGroup: room.type == "group")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.body)
                            .lineLimit(1)
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if muted {
                            Image(systemName: "bell.slash.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(TimeUtil.formatListTime(preview?.ts ?? room.createdAt))
                            .font(.caption)
                            .foregroundStyle(room.unread > 0 ? .primary : .secondary)
                    }
                    HStack(spacing: 6) {
                        Text(preview?.text ?? "开始聊天")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if room.unread > 0 {
                            Text("\(room.unread)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.red, in: Capsule())
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                vm.markReadLocally(room.id)
                appState.chatListVersion += 1
            } label: {
                Label("已读", systemImage: "checkmark")
            }
            .tint(.blue)
            Button {
                vm.toggleMuted(room.id)
            } label: {
                Label(muted ? "开免打扰" : "关免打扰", systemImage: "bell.slash")
            }
            .tint(.orange)
            Button {
                vm.togglePinned(room.id)
            } label: {
                Label(pinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(.gray)
            Button(role: .destructive) {
                vm.deleteChatRecords(room.id)
                vm.markReadLocally(room.id)
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                vm.markReadLocally(room.id)
                appState.chatListVersion += 1
            } label: {
                Label("标记已读", systemImage: "checkmark")
            }
            Button {
                vm.toggleMuted(room.id)
            } label: {
                Label(muted ? "关闭免打扰" : "开启免打扰", systemImage: "bell.slash")
            }
            Button {
                vm.togglePinned(room.id)
            } label: {
                Label(pinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            Button(role: .destructive) {
                vm.deleteChatRecords(room.id)
                vm.markReadLocally(room.id)
            } label: {
                Label("删除聊天记录", systemImage: "trash")
            }
        }
    }

    // MARK: 未登录:引导
    private var notLoggedIn: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("登录后可查看聊天")
                    .font(.headline)
                Text("账号聊天登录后显示;临时聊天与邀请聊天无需登录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Button {
                        showLogin = true
                    } label: {
                        Label("登录 / 注册", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        showTempChat = true
                    } label: {
                        Label("发起临时聊天", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 48)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("聊天")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有会话")
                .font(.headline)
            Text("点右上角「+」发起聊天、创建邀请或临时聊天")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 头像组件(蓝/靛渐变 + 首字母,深浅色通用)

struct ChatAvatar: View {
    let label: String
    var isGroup = false
    /// 直径(默认 44;调用方需要更大/更小时传 size,而不是外面套 frame)
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(isGroup ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(Color.blue.gradient))
                .frame(width: size, height: size)
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.41))
                    .foregroundStyle(.white)
            } else {
                Text(String(label.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(label)
    }
}
