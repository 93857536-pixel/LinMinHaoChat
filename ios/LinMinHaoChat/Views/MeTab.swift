import PhotosUI
import SwiftUI
import UIKit

/// 我的 Tab —— 账号信息 + 隐私与安全 + 诊断支持 + 关于 + 登录/登出。
/// 保留原有设置页(隐私模式强制、诊断日志上传、关于)全部功能,重组进"我的"。
///
/// ⚠️ 退出登录只保留一处:进入「账号与安全」(AccountDetail)后的那一个。
/// 本页**不再**放置独立的「退出登录」区(用户明确要求:两个登出按钮只留里面的)。
struct MeTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var showLogin = false
    @State private var logContent = ""
    @State private var showLogSheet = false
    @State private var showNicknameEdit = false
    @State private var showRealName = false
    @State private var uploadStatus: UploadStatus = .idle
    // 头像上传
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarBusy = false
    @State private var avatarError: String?
    @State private var showAvatarActions = false

    enum UploadStatus: Equatable {
        case idle, uploading, success, failed(String)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                // 账号区
                Section {
                    if appState.isLoggedIn {
                        HStack(spacing: 16) {
                            // 点头像直接换:相册选图 → 压方图 → 上传
                            PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                                ZStack {
                                    UserAvatar(
                                        userId: appState.userId ?? 0,
                                        label: appState.displayName,
                                        hasAvatar: appState.avatarUpdatedAt != nil,
                                        size: 56
                                    )
                                    if avatarBusy {
                                        Circle().fill(.black.opacity(0.35)).frame(width: 56, height: 56)
                                        ProgressView().tint(.white)
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Color.accentColor, in: Circle())
                                        .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                                        .offset(x: 2, y: 2)
                                }
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(appState.displayName)
                                    .font(.title3.weight(.semibold))
                                Text("账号 ID \(appState.userHandle ?? "—") · 已登录")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("点头像可更换")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 6)
                    } else {
                        Button {
                            showLogin = true
                        } label: {
                            HStack(spacing: 16) {
                                ChatAvatar(label: "未", isGroup: false)
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("未登录")
                                        .font(.title3.weight(.semibold))
                                    Text("登录 / 注册以开启账号聊天")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                // 登录 / 账号管理
                Section("账号") {
                    if appState.isLoggedIn {
                        NavigationLink {
                            AccountDetail()
                                .environmentObject(appState)
                        } label: {
                            meRow("账号与安全", icon: "lock.shield", tint: .gray)
                        }
                        Button {
                            showNicknameEdit = true
                        } label: {
                            HStack(spacing: 12) {
                                meIcon("pencil", .blue)
                                Text("修改账号名称")
                                Spacer()
                                Text(appState.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                            HStack(spacing: 12) {
                                meIcon("photo.circle", .purple)
                                Text(appState.avatarUpdatedAt == nil ? "上传头像" : "更换头像")
                                Spacer()
                                if avatarBusy { ProgressView().controlSize(.small) }
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        if appState.avatarUpdatedAt != nil {
                            Button {
                                showAvatarActions = true
                            } label: {
                                HStack(spacing: 12) {
                                    meIcon("trash", .red)
                                    Text("移除头像").foregroundStyle(.red)
                                    Spacer()
                                }
                            }
                        }
                        Button {
                            showRealName = true
                        } label: {
                            HStack(spacing: 12) {
                                meIcon("person.text.rectangle", .green)
                                Text("实名认证")
                                Spacer()
                                if appState.realnameVerified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption).foregroundStyle(.green)
                                    Text(appState.realnameNameMasked ?? "已认证")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("未认证")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Button {
                            showLogin = true
                        } label: {
                            meRow("登录 / 注册", icon: "person.badge.plus", tint: .blue)
                        }
                    }
                }

                // 隐私与安全(核心特性,不删)
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                            .frame(width: 36, height: 36)
                            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("隐私模式")
                            Text("永久开启 · 不可关闭")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("隐私与安全")
                } footer: {
                    Text("端到端加密:消息在设备上加密,服务器只保存密文,没有私钥、没有万能密钥。私钥仅存本机 Keychain,绝不上传。聊天界面无水印,App 进入后台自动模糊,应用切换器不泄露内容。")
                }

                Section("安全特性") {
                    LabeledContent("加密", value: "AES-256-GCM 端到端")
                    LabeledContent("密钥", value: "本机 Keychain")
                    LabeledContent("水印", value: "无")
                    LabeledContent("后台隐私", value: "强制模糊")
                }

                // 诊断支持(保留原 SettingsView 日志上传)
                if appState.isLoggedIn {
                    Section("诊断支持") {
                        Button {
                            Task { await loadLogContent() }
                        } label: {
                            HStack(spacing: 10) {
                                meIcon("doc.text.magnifyingglass", .blue)
                                Text("查看一键登录日志")
                                Spacer()
                                if case .uploading = uploadStatus { ProgressView() }
                            }
                        }
                        Button {
                            Task { await uploadLog() }
                        } label: {
                            HStack(spacing: 10) {
                                meIcon("arrow.up.circle.fill", .green)
                                Text("上传日志到服务器")
                                Spacer()
                                switch uploadStatus {
                                case .uploading: ProgressView()
                                case .success: meIcon("checkmark.circle.fill", .green)
                                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
                                default: EmptyView()
                                }
                            }
                        }
                        .disabled(uploadStatus == .uploading)
                    }
                }

                Section {
                    Button(role: nil) {
                        if let url = URL(string: "https://help.aliyun.com/zh/pnvs/developer-reference/the-preparatory-work-2/") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        meRow("帮助与支持", icon: "questionmark.circle", tint: .gray)
                    }
                }

                Section("消息管理") {
                    NavigationLink {
                        StarredListView()
                    } label: {
                        meRow("收藏消息", icon: "star.fill", tint: .orange)
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("客户端", value: "原生 iOS(SwiftUI + CryptoKit)")
                    LabeledContent("后端", value: "chat.linminhao.top")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLogin) {
                LoginView(preferRegister: false)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showLogSheet) {
                LogContentView(logContent: logContent)
            }
            .sheet(isPresented: $showNicknameEdit) {
                NicknameEditSheet()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showRealName) {
                RealNameView()
                    .environmentObject(appState)
            }
            .onChange(of: avatarItem) { _, item in
                Task { await pickAvatar(item) }
            }
            .confirmationDialog("头像", isPresented: $showAvatarActions, titleVisibility: .visible) {
                Button("移除头像", role: .destructive) { Task { await removeAvatar() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("移除后,好友与搜索结果中都显示默认头像。")
            }
            .alert("头像", isPresented: Binding(get: { avatarError != nil },
                                              set: { if !$0 { avatarError = nil } })) {
                Button("好", role: .cancel) { avatarError = nil }
            } message: {
                Text(avatarError ?? "")
            }
        }
    }

    // MARK: 头像上传(相册选图 → AvatarStore 压方图/上传)

    @MainActor
    private func pickAvatar(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        avatarBusy = true
        defer { avatarBusy = false; avatarItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else {
                avatarError = "无法读取所选图片,请换一张再试"
                return
            }
            try await AvatarStore.shared.upload(img)
        } catch {
            if let e = error as? ApiError, e.status == 413 {
                avatarError = "图片过大,请换一张"
            } else {
                avatarError = "上传失败:\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func removeAvatar() async {
        do {
            try await AvatarStore.shared.removeMyAvatar()
        } catch {
            avatarError = "移除失败:\(error.localizedDescription)"
        }
    }

    // MARK: 行组件
    private func meRow(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            meIcon(icon, tint)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func meIcon(_ system: String, _ tint: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: 日志(迁移自原 SettingsView)
    private func loadLogContent() async {
        uploadStatus = .uploading
        do {
            logContent = PNSAuthManager.shared.getLogContent()
            showLogSheet = true
            uploadStatus = .success
        } catch {
            uploadStatus = .failed("读取失败")
        }
    }

    private func uploadLog() async {
        // 首次点击时日志还没读进内存:先读取,再继续上传(旧逻辑这里直接 return,
        // 导致必须点两次才开始上传 —— 用户会误以为按钮坏了)
        if logContent.isEmpty {
            logContent = PNSAuthManager.shared.getLogContent()
        }
        showLogSheet = true   // 让用户看到本次实际发出的内容
        guard !logContent.isEmpty else {
            uploadStatus = .failed("暂无日志可上传")
            return
        }
        uploadStatus = .uploading
        do {
            let device = UIDevice.current
            let meta: [String: String] = [
                "os": device.systemName + " " + device.systemVersion,
                "device": device.model,
                "appVersion": appVersion,
                "locale": Locale.current.identifier,
            ]
            let _: Empty = try await APIClient.request(
                "/diag/upload",
                body: ["log": logContent, "meta": meta]
            )
            uploadStatus = .success
        } catch {
            uploadStatus = .failed("上传失败:\(error.localizedDescription)")
        }
    }
}

// MARK: - 账号与安全(登出/设备信息)

struct AccountDetail: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showNicknameEdit = false
    @State private var showBindPhone = false
    @State private var showBindEmail = false

    var body: some View {
        List {
            Section {
                LabeledContent("账号名称", value: appState.displayName)
                LabeledContent("账号 ID", value: appState.userHandle ?? "—")
                if let phone = appState.phoneMasked {
                    LabeledContent("已绑手机", value: phone)
                }
                if let email = appState.emailMasked {
                    LabeledContent("已绑邮箱", value: email)
                }
                LabeledContent("设备身份", value: appState.identity?.deviceId ?? "—")
                LabeledContent("会话", value: appState.sessionId.map { String($0.prefix(8)) + "…" } ?? "—")
            } header: {
                Text("当前账号")
            } footer: {
                Text("账号 ID 由系统按注册时间自动生成（如 202210216pm.A），全网唯一且不可修改；账号名称可随时更改。支持同时绑定手机号和邮箱，两种通道均可用于登录。")
            }

            // 绑定凭据入口
            if appState.isLoggedIn {
                Section("绑定凭据") {
                    if appState.phoneMasked == nil {
                        Button {
                            showBindPhone = true
                        } label: {
                            HStack {
                                Image(systemName: "iphone").foregroundStyle(.blue)
                                Text("绑定手机号")
                                Spacer()
                                Text("用于登录").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("手机号已绑定: \(appState.phoneMasked!)")
                        }
                        .font(.subheadline)
                    }
                    if appState.emailMasked == nil {
                        Button {
                            showBindEmail = true
                        } label: {
                            HStack {
                                Image(systemName: "envelope").foregroundStyle(.blue)
                                Text("绑定邮箱")
                                Spacer()
                                Text("用于登录").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("邮箱已绑定: \(appState.emailMasked!)")
                        }
                        .font(.subheadline)
                    }
                }
            }

            Section("账号名称") {
                Button {
                    showNicknameEdit = true
                } label: {
                    HStack {
                        Image(systemName: "pencil")
                        Text("修改账号名称")
                        Spacer()
                        Text(appState.displayName).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("退出登录", role: .destructive) {
                    appState.logout()
                    dismiss()
                }
            }
        }
        .navigationTitle("账号与安全")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNicknameEdit) {
            NicknameEditSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showBindPhone) {
            CredentialBindSheet(type: "sms", title: "绑定手机号")
                .environmentObject(appState)
        }
        .sheet(isPresented: $showBindEmail) {
            CredentialBindSheet(type: "email", title: "绑定邮箱")
                .environmentObject(appState)
        }
        .onAppear {
            // 刷新账号资料以显示最新绑定状态
            Task { await appState.refreshProfile() }
        }
    }
}

// MARK: - 修改账号名称

struct NicknameEditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("输入新的账号名称", text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: text) { _, v in
                            if v.count > 24 { text = String(v.prefix(24)) }
                        }
                } header: {
                    Text("账号名称")
                } footer: {
                    Text("账号名称最多 24 个字符，可随时修改。账号 ID（\(appState.userHandle ?? "—")）由系统自动生成，不可更改。")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("修改账号名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(trimmed.isEmpty || trimmed == appState.displayName)
                    }
                }
            }
            .onAppear {
                text = appState.userNickname ?? appState.userHandle ?? ""
                focused = true
            }
        }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        guard let token = appState.authToken else { return }
        let name = trimmed
        guard !name.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let u = try await AuthAPI.updateNickname(name, token: token)
            appState.userNickname = u.nickname ?? name
            if let h = u.handle { appState.userHandle = h }
            UserDefaults.standard.set(appState.userNickname, forKey: "lmh.auth.nickname")
            dismiss()
        } catch {
            if let e = error as? ApiError, e.status == 429 {
                errorMessage = "修改过于频繁，请稍后再试"
            } else {
                errorMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 绑定凭据(手机/邮箱)

struct CredentialBindSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let type: String  // "sms" or "email"
    let title: String

    @State private var target = ""
    @State private var code = ""
    @State private var isSending = false
    @State private var isBinding = false
    @State private var errorMessage: String?
    @State private var countdown = 0

    private var isEmail: Bool { type == "email" }

    /// 目标输入是否有效:手机号 11 位 / 邮箱含 @ 且带域点(前端轻校验,服务端仍严格校验)
    private var targetValid: Bool {
        if isEmail {
            let parts = target.split(separator: "@")
            return parts.count == 2 && !parts[0].isEmpty
                && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
        }
        return target.count >= 11
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isEmail ? "输入邮箱地址" : "输入手机号", text: $target)
                        .keyboardType(isEmail ? .emailAddress : .phonePad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    // 验证码输入与发送按钮:手机/邮箱绑定都需要(服务端统一校验 6 位码)
                    // 行样式跟随 Form 默认(与「输入邮箱/手机号」行一致),
                    // 早期曾给这两行单独加 clear 背景+窄框导致视觉割裂(2026-11-14 用户指出)
                    TextField("验证码", text: $code)
                        .keyboardType(.numberPad)
                    HStack {
                        Button(action: { Task { await sendCode() } }) {
                            Text(countdown > 0 ? "\(countdown)s后重试" : "发送验证码")
                                .foregroundColor(countdown > 0 ? .secondary : .blue)
                        }
                        .disabled(countdown > 0 || isSending || !targetValid)
                        Spacer()
                        if isSending { ProgressView() }
                    }
                } header: {
                    Text("输入要绑定的\(isEmail ? "邮箱" : "手机号")")
                } footer: {
                    Text(isEmail ? "绑定邮箱后可使用该邮箱登录账号" : "绑定手机号后可使用该手机号登录账号")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isBinding {
                        ProgressView()
                    } else {
                        Button("确认绑定") { Task { await bind() } }
                            .disabled(target.isEmpty || !targetValid || code.isEmpty || isSending)
                    }
                }
            }
        }
    }

    private func sendCode() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            _ = try await AuthAPI.sendCode(type: type, target: target)
            countdown = 60
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if countdown > 0 {
                    countdown -= 1
                } else {
                    timer.invalidate()
                }
            }
        } catch {
            if let e = error as? ApiError, e.status == 429 {
                errorMessage = "发送过于频繁，请稍后再试"
            } else {
                errorMessage = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    private func bind() async {
        guard let token = appState.authToken else { return }
        isBinding = true
        errorMessage = nil
        defer { isBinding = false }
        do {
            _ = try await AuthAPI.bindCredential(bindType: "bind", type: type, target: target, code: code, token: token)
            await appState.refreshProfile()
            dismiss()
        } catch {
            if let e = error as? ApiError {
                switch e.status {
                case 401: errorMessage = "验证码错误或已过期"
                case 409: errorMessage = "该\(isEmail ? "邮箱" : "手机号")已被其他账号绑定"
                case 429: errorMessage = "操作过于频繁，请稍后再试"
                default: errorMessage = "绑定失败：\(e.message)"
                }
            } else {
                errorMessage = "绑定失败：\(error.localizedDescription)"
            }
        }
    }
}
