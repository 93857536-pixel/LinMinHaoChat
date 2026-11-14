import SwiftUI
import CryptoKit

/// 群聊成员管理视图
struct MemberManageView: View {
    let roomId: String
    let sessionToken: String
    /// 可选的会话密钥提供者(用于改名加密;nil = 从非聊天页面打开,不支持改名)
    var sessionKeyProvider: (() -> SymmetricKey?)? = nil
    @StateObject private var viewModel = MemberManageViewModel()
    @State private var showAddSheet = false
    @State private var searchQuery = ""
    @State private var errorMessage: String?
    @State private var showRenameSheet = false
    @State private var newGroupName = ""
    @State private var isRenaming = false

    var body: some View {
        NavigationStack {
            List {
                // 群名称(仅创建者可改名,需有可用的会话密钥)
                if viewModel.isCreator, sessionKeyProvider != nil {
                    Section("群名称") {
                        HStack {
                            Text(newGroupName.isEmpty ? "点击修改群名称" : newGroupName)
                                .foregroundStyle(newGroupName.isEmpty ? .secondary : .primary)
                            Spacer()
                            if isRenaming {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showRenameSheet = true }
                    }
                }

                // 创建者信息
                if viewModel.isCreator {
                    Section("创建者") {
                        if let creator = viewModel.members.first(where: { $0.isCreator }) {
                            memberRow(member: creator)
                        }
                    }
                }
                
                // 其他成员
                Section {
                    if viewModel.members.filter({ !$0.isCreator }).isEmpty {
                        Text("暂无其他成员")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(viewModel.members.filter({ !$0.isCreator })) { member in
                            memberRow(member: member)
                        }
                    }
                } header: {
                    Text("成员 (\(viewModel.members.count))")
                } footer: {
                    if viewModel.isCreator {
                        Text("创建者可管理成员")
                    } else {
                        Text("仅创建者可管理")
                    }
                }
            }
            .navigationTitle("成员管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isCreator {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("添加", systemImage: "person.badge.plus")
                        }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("退出群聊") {
                            Task { await viewModel.leaveRoom(roomId: roomId, token: sessionToken) }
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddMemberSheet(searchQuery: $searchQuery) { userId in
                    Task { await viewModel.addMember(roomId: roomId, userId: userId, token: sessionToken) }
                }
            }
            .sheet(isPresented: $showRenameSheet) {
                GroupNameEditSheet(currentName: newGroupName) { newName in
                    Task {
                        if let key = sessionKeyProvider?() {
                            do {
                                isRenaming = true
                                try await viewModel.renameRoom(newName: newName, roomId: roomId, token: sessionToken, sessionKey: key)
                                newGroupName = newName
                            } catch {
                                errorMessage = "改名失败:\(error.localizedDescription)"
                            }
                            isRenaming = false
                        }
                    }
                }
            }
            .task { await viewModel.loadMembers(roomId: roomId, token: sessionToken) }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
    
    @ViewBuilder
    private func memberRow(member: MemberManageViewModel.MemberItem) -> some View {
        HStack(spacing: 12) {
            UserAvatar(userId: member.userId,
                       label: member.displayName,
                       hasAvatar: member.hasAvatar,
                       size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(member.displayName)
                        .font(.body)
                    if member.isCreator {
                        Text("创建者")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("加入时间: \(TimeUtil.formatDate(member.joinedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isCreator && !member.isCreator {
                Button(role: .destructive) {
                    Task { await viewModel.removeMember(roomId: roomId, userId: member.userId, token: sessionToken) }
                } label: {
                    Image(systemName: "person.badge.minus")
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel
@MainActor
final class MemberManageViewModel: ObservableObject {
    struct MemberItem: Identifiable {
        let id: Int
        let userId: Int
        let handle: String?
        let nickname: String?
        let hasAvatar: Bool
        let joinedAt: Int64
        let isCreator: Bool
        var displayName: String { (nickname?.isEmpty == false ? nickname! : (handle ?? "账号\(userId)")) }
    }
    
    @Published var members: [MemberItem] = []
    @Published var isCreator = false
    @Published var isLoading = false
    
    func loadMembers(roomId: String, token: String) async {
        guard !roomId.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await ChatAPI.getMembers(roomId, token: token)
            isCreator = result.isCreator
            members = result.members.map { m in
                MemberItem(id: m.userId, userId: m.userId, handle: m.handle, nickname: m.nickname,
                           hasAvatar: m.hasAvatar == true, joinedAt: m.joinedAt, isCreator: m.isCreator)
            }
        } catch {
            print("[MemberManage] loadMembers error: \(error)")
        }
    }
    
    func addMember(roomId: String, userId: Int, token: String) async {
        do {
            try await ChatAPI.addMember(roomId, userId: userId, token: token)
            await loadMembers(roomId: roomId, token: token)
        } catch {
            print("[MemberManage] addMember error: \(error)")
        }
    }
    
    func removeMember(roomId: String, userId: Int, token: String) async {
        do {
            try await ChatAPI.removeMember(roomId, userId: userId, token: token)
            await loadMembers(roomId: roomId, token: token)
        } catch {
            print("[MemberManage] removeMember error: \(error)")
        }
    }
    
    func leaveRoom(roomId: String, token: String) async {
        do {
            try await ChatAPI.leaveRoom(roomId, token: token)
        } catch {
            print("[MemberManage] leaveRoom error: \(error)")
        }
    }

    /// 修改群名称(仅创建者):加密新名上传 + 更新本地缓存
    func renameRoom(newName: String, roomId: String, token: String, sessionKey: SymmetricKey) async throws {
        let now = Date().timeIntervalSince1970
        let ts64 = Int64(now * 1000)
        let encPayload = try MessageCrypto.encryptMessage(
            sessionKey: sessionKey, plaintext: newName,
            roomId: roomId, seq: Int(ts64), ts: ts64
        )
        let nameEnc = "\(encPayload.iv):\(encPayload.ct)"
        _ = try await ChatAPI.renameRoom(roomId, nameEnc: nameEnc, token: token)
        UserDefaults.standard.set(newName, forKey: "lmh.room.label.\(roomId)")
        AppState.shared.chatListVersion += 1
    }
}

// MARK: - 添加成员面板
struct AddMemberSheet: View {
    @Binding var searchQuery: String
    let onSelect: (Int) -> Void
    @State private var candidates: [FriendsAPI.SearchUser] = []
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索好友昵称", text: $searchQuery)
                        .autocorrectionDisabled()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if !searchQuery.isEmpty {
                        Button("清除") { searchQuery = "" }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                
                List(candidates) { friend in
                    Button {
                        onSelect(friend.userId)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            UserAvatar(userId: friend.userId, label: friend.displayName,
                                       hasAvatar: friend.hasAvatar, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.displayName)
                                    .font(.body)
                                if let phone = friend.phoneMasked {
                                    Text(phone)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if friend.isFriend {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("添加成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await loadFriends() }
        }
    }
    
    private func loadFriends() async {
        guard let token = AppState.shared.authToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            candidates = try await FriendsAPI.search(searchQuery, token: token)
        } catch {
            print("[AddMember] search error: \(error)")
        }
    }
}

// MARK: - 群名编辑面板
struct GroupNameEditSheet: View {
    let currentName: String
    let onSave: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("群名称") {
                    TextField("请输入群名称", text: $name)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("修改群名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSave(trimmed) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { name = currentName }
        }
    }
}

// MARK: - 辅助
extension TimeUtil {
    static func formatDate(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}