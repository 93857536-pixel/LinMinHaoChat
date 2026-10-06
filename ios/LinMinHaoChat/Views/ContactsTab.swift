import SwiftUI

/// 通讯录 Tab —— 我的账号 + 常用联系人(本机) + 发起聊天入口。
/// 服务器无好友系统,这里"常用联系人"仅存本机(不上传),作为发起私聊的快捷入口。
struct ContactsTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = CommonContactsStore.shared
    @State private var showAddContact = false
    @State private var dmPrefill = ""
    @State private var showNewDM = false

    var body: some View {
        NavigationStack {
            List {
                if appState.isLoggedIn {
                    Section {
                        NavigationLink(value: "self") {
                            HStack(spacing: 12) {
                                ChatAvatar(label: appState.userHandle ?? "我", isGroup: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appState.userHandle ?? "已登录")
                                        .font(.body)
                                    Text("账号 \(appState.userId.map(String.init) ?? "—")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("我的账号")
                    }
                }

                Section("常用联系人") {
                    if store.contacts.isEmpty {
                        HStack {
                            Text("还没有常用联系人")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
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
            .listStyle(.insetGrouped)
            .navigationTitle("通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showAddContact = true
                        } label: {
                            Label("添加联系人", systemImage: "person.badge.plus")
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
            .navigationDestination(for: String.self) { value in
                if value == "self" {
                    MeAccountView()
                        .environmentObject(appState)
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddContactSheet(onSaved: { _, _ in })
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showNewDM) {
                NewDMSheet(prefillUserId: dmPrefill) { _, name in
                    // 记住常用联系人(以发起前填写的对方 ID 为准;onCreated 首参是 roomId 非 userId)
                    if let uid = Int(dmPrefill) { store.remember(userId: uid, name: name) }
                }
                .environmentObject(appState)
            }
        }
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
                    ChatAvatar(label: appState.userHandle ?? "我")
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.userHandle ?? "未登录")
                            .font(.title3.weight(.semibold))
                        Text(appState.isLoggedIn ? "账号 ID \(appState.userId.map(String.init) ?? "—")" : "尚未登录")
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

// MARK: - 添加联系人 sheet(本机保存;ID 填了才生成聊天入口)

struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var userId = ""
    let onSaved: (Int, String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示名称(可选)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("如:林某", text: $name)
                        .textFieldStyle(.roundedBorder)
                    Text("用户 ID(发起聊天必需)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("数字 ID", text: $userId)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 20)

                Button {
                    if let uid = Int(userId) {
                        let n = name.isEmpty ? "账号 \(uid)" : name
                        CommonContactsStore.shared.remember(userId: uid, name: n)
                        onSaved(uid, n)
                        dismiss()
                    }
                } label: {
                    Text("保存")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(userId.isEmpty || !userId.allSatisfy(\.isNumber))
                .padding(.horizontal, 20)

                Spacer()
            }
            .navigationTitle("添加联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
