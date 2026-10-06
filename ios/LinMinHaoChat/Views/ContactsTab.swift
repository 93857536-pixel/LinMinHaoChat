import SwiftUI

/// 通讯录 Tab —— 服务端好友系统为主,本机常用联系人为辅。
/// 未登录:仅本机联系人与发起聊天;已登录:多「我的好友」「查找」入口。
struct ContactsTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = CommonContactsStore.shared

    @State private var friends: [FriendsAPI.Friend] = []
    @State private var loadingFriends = false
    @State private var findQuery: String?
    @State private var showFindFriends = false
    @State private var dmPrefill = ""
    @State private var showNewDM = false

    var body: some View {
        NavigationStack {
            List {
                if appState.isLoggedIn {
                    // 我的账号
                    Section("我的账号") {
                        NavigationLink {
                            MeAccountView()
                        } label: {
                            HStack(spacing: 12) {
                                ChatAvatar(label: appState.displayName, isGroup: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appState.displayName)
                                        .font(.body)
                                    Text("账号 \(appState.userHandle ?? "—")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // 服务端好友(数据源 = /api/friends)
                    Section("我的好友") {
                        if loadingFriends {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if friends.isEmpty {
                            HStack {
                                Text("还没有好友,点右上角「+ → 查找」添加")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        ForEach(friends) { f in
                            friendRow(f)
                        }
                        .onDelete { deleteFriends(at: $0) }
                    }
                }

                // 本机常用联系人(离线可用,仅本机存储)
                if !store.contacts.isEmpty {
                    Section("常用联系人(本机)") {
                        ForEach(store.contacts) { c in
                            HStack(spacing: 12) {
                                ChatAvatar(label: c.name, isGroup: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                    Text("ID \(c.userId)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("发起聊天") {
                                        dmPrefill = String(c.userId)
                                        showNewDM = true
                                    }
                                    .disabled(!appState.isLoggedIn)
                                    Button("删除", role: .destructive) { store.remove(c) }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if appState.isLoggedIn {
                            Button {
                                showFindFriends = true
                            } label: {
                                Label("查找", systemImage: "person.badge.plus")
                            }
                            Button {
                                loadFriends()
                            } label: {
                                Label("刷新好友", systemImage: "arrow.clockwise")
                            }
                        }
                        Button {
                            dmPrefill = ""
                            showNewDM = true
                        } label: {
                            Label("发起聊天", systemImage: "bubble.left.and.bubble.right")
                        }
                        .disabled(!appState.isLoggedIn)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showFindFriends) {
                FindFriendsSheet()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showNewDM) {
                NewDMSheet(prefillUserId: dmPrefill) { _, name in
                    if let uid = Int(dmPrefill) {
                        store.remember(userId: uid, name: name)
                    }
                }
                .environmentObject(appState)
            }
            .task {
                if appState.isLoggedIn { loadFriends() }
            }
            .refreshable { if appState.isLoggedIn { loadFriends() } }
        }
    }

    // MARK: - 好友行

    private func friendRow(_ f: FriendsAPI.Friend) -> some View {
        HStack(spacing: 12) {
            ChatAvatar(label: f.handle, isGroup: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.handle)
                    if f.initiator == "theirs" {
                        Text("TA 加你")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(Color.accentColor)
                            .cornerRadius(5)
                    }
                }
                Text(friendMaskLine(f))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("发起聊天") {
                    dmPrefill = String(f.userId)
                    showNewDM = true
                }
                Button("删除好友", role: .destructive) {
                    if let token = appState.authToken {
                        let uid = f.userId
                        Task {
                            try? await FriendsAPI.remove(uid, token: token)
                            friends.removeAll { $0.userId == uid }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private func friendMaskLine(_ f: FriendsAPI.Friend) -> String {
        var parts: [String] = []
        if let p = f.phoneMasked, !p.isEmpty { parts.append(p) }
        if let e = f.emailMasked, !e.isEmpty { parts.append(e) }
        return parts.isEmpty ? "ID \(f.userId)" : parts.joined(separator: " · ")
    }

    // MARK: - 数据

    private func loadFriends() {
        guard appState.isLoggedIn, !loadingFriends, let token = appState.authToken else { return }
        loadingFriends = true
        Task {
            do {
                friends = try await FriendsAPI.list(token: token)
            } catch {
                friends = []
            }
            loadingFriends = false
        }
    }

    private func deleteFriends(at offsets: IndexSet) {
        let removed = offsets.map { friends[$0] }
        if let token = appState.authToken {
            for f in removed {
                Task { try? await FriendsAPI.remove(f.userId, token: token) }
            }
        }
        friends.remove(atOffsets: offsets)
    }
}

// MARK: - 我的账号卡片(通讯录点进)

struct MeAccountView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ChatAvatar(label: appState.displayName)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.isLoggedIn ? appState.displayName : "未登录")
                            .font(.title3.weight(.semibold))
                        Text(appState.isLoggedIn ? "账号 ID \(appState.userHandle ?? "—")" : "尚未登录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            if appState.isLoggedIn {
                Section("账号状态") {
                    LabeledContent("登录状态", value: "已登录")
                    LabeledContent("设备身份", value: appState.identity?.deviceId ?? "—")
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("我的账号")
        .navigationBarTitleDisplayMode(.inline)
    }
}
