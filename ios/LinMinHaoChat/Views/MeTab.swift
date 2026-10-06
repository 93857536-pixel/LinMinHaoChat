import SwiftUI

/// 我的 Tab —— 账号信息 + 隐私与安全 + 诊断支持 + 关于 + 登录/登出。
/// 保留原有设置页(隐私模式强制、诊断日志上传、关于)全部功能,重组进"我的"。
struct MeTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var showLogin = false
    @State private var logContent = ""
    @State private var showLogSheet = false
    @State private var uploadStatus: UploadStatus = .idle

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
                            ChatAvatar(label: appState.userHandle ?? "我")
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(appState.userHandle ?? "已登录")
                                    .font(.title3.weight(.semibold))
                                Text("账号 ID \(appState.userId.map(String.init) ?? "—") · 已登录")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
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

                if appState.isLoggedIn {
                    Section {
                        Button("退出登录", role: .destructive) {
                            appState.logout()
                        }
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
        guard !logContent.isEmpty else {
            await loadLogContent()
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

    var body: some View {
        List {
            Section("当前账号") {
                LabeledContent("用户名", value: appState.userHandle ?? "—")
                LabeledContent("账号 ID", value: appState.userId.map(String.init) ?? "—")
                LabeledContent("设备身份", value: appState.identity?.deviceId ?? "—")
                LabeledContent("会话", value: appState.sessionId.map { String($0.prefix(8)) + "…" } ?? "—")
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
    }
}
