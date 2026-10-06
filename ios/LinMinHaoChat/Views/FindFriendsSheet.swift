import SwiftUI

/// 查找好友 —— 服务端按 handle 模糊 / 号码末 4 位搜索(脱敏结果)。
/// 操作:添加好友(双向互加,即时生效)/ 发起私聊。
struct FindFriendsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FriendsAPI.SearchUser] = []
    @State private var searching = false
    @State private var searched = false
    @State private var errorText: String?
    @State private var dmPrefill = ""
    @State private var showNewDM = false
    @State private var busyUserId: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索昵称或号码后 4 位", text: $query)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    if searching {
                        ProgressView().controlSize(.small)
                    } else if !query.isEmpty {
                        Button("x") { query = "" }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // 结果列表
                if searched && results.isEmpty && errorText == nil {
                    Spacer()
                    Text("没有找到匹配的用户")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if let err = errorText {
                    Spacer()
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Spacer()
                }
                if !results.isEmpty {
                    List(results) { u in
                        HStack(spacing: 12) {
                            UserAvatar(userId: u.userId, label: u.displayName, hasAvatar: u.hasAvatar, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.displayName)
                                Text(displayMask(u))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if u.isFriend {
                                Button {
                                    dmPrefill = String(u.userId)
                                    showNewDM = true
                                } label: {
                                    Label("聊天", systemImage: "bubble.left")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!appState.isLoggedIn)
                            } else {
                                Button {
                                    Task { await addFriend(u) }
                                } label: {
                                    if busyUserId == u.userId {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("添加", systemImage: "person.badge.plus")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!appState.isLoggedIn)
                            }
                        }
                    }
                }
            }
            .navigationTitle("查找好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showNewDM) {
                NewDMSheet(prefillUserId: dmPrefill) { _, _ in }
                    .environmentObject(appState)
            }
        }
    }

    private func displayMask(_ u: FriendsAPI.SearchUser) -> String {
        var parts: [String] = ["账号 \(u.handle)"]
        if let p = u.phoneMasked, !p.isEmpty { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    private func search() async {
        guard appState.isLoggedIn, let token = appState.authToken,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        errorText = nil
        defer { searching = false; searched = true }
        do {
            results = try await FriendsAPI.search(query, token: token)
        } catch {
            results = []
            errorText = error.localizedDescription
        }
    }

    private func addFriend(_ u: FriendsAPI.SearchUser) async {
        guard appState.isLoggedIn, let token = appState.authToken else { return }
        busyUserId = u.userId
        defer { busyUserId = nil }
        do {
            try await FriendsAPI.add(u.userId, token: token)
            // 乐观更新:标记该用户为已是好友(SearchUser 是 struct,改副本)
            results = results.map { item in
                guard item.userId == u.userId else { return item }
                var x = item
                x.isFriend = true
                return x
            }
        } catch {
            errorText = "添加失败:\(error.localizedDescription)"
        }
    }
}
