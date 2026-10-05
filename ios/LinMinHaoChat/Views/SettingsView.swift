import SwiftUI
import UniformTypeIdentifiers

/// 设置页:隐私模式(强制,不可关闭)+ 服务器信息 + 关于
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showLogSheet = false
    @State private var logContent = ""
    @State private var uploadStatus: UploadStatus = .idle

    enum UploadStatus: Equatable {
        case idle, uploading, success, failed(String)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("隐私模式")
                    Spacer()
                    Text("永久开启")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("隐私模式没有关闭按钮、没有设置开关:聊天界面不显示水印,消息端到端加密,服务器只保存密文,私钥仅存本机 Keychain。")
            }

            Section("隐私模式详情") {
                Text(PrivacyMode.statement)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("后端", value: "chat.linminhao.top")
                LabeledContent("连接方式", value: "App 自动连接")
                LabeledContent("存储", value: "仅加密密文")
            } header: {
                Text("服务器")
            } footer: {
                Text("用户不需要知道服务器地址 —— App 内部自动处理(产品定位第五条)。")
            }

            // 一键登录日志上传
            if appState.isLoggedIn {
                Section("诊断支持") {
                    Button {
                        Task { await loadLogContent() }
                    } label: {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("查看一键登录日志")
                            Spacer()
                            if case .uploading = uploadStatus {
                                ProgressView()
                            }
                        }
                    }
                    
                    Button {
                        Task { await uploadLog() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("上传日志到服务器")
                            Spacer()
                            switch uploadStatus {
                            case .uploading:
                                ProgressView()
                            case .success:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed(let msg):
                                Text(msg).foregroundStyle(.red)
                            default:
                                EmptyView()
                            }
                        }
                    }
                    .disabled(uploadStatus == .uploading)
                    
                    Text("上传日志有助于我们快速定位一键登录失败问题(网络连接丢失等)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("查看帮助文档") {
                    if let url = URL(string: "https://help.aliyun.com/zh/pnvs/developer-reference/the-preparatory-work-2/") {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("帮助与支持")
            } footer: {
                Text("如遇网络连接问题,请先确认已开启蜂窝数据并插入SIM卡")
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
                LabeledContent("SDK版本", value: sdkVersion)
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showLogSheet) {
            LogContentView(logContent: logContent)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var sdkVersion: String {
        #if canImport(ATAuthSDK)
        return TXCommonHandler.sharedInstance().getVersion()
        #else
        return "未集成"
        #endif
    }

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
            // 端点 POST /api/diag/upload(免认证,IP 限流 10 次/分,落盘 diag-logs/)
            // /api/logs/device 被 Cloudflare ingress 的 /api/logs->8083 规则误拦 403,
            // 故用独立 /api/diag 前缀绕过。body: { log, meta }
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

/// 日志内容查看视图
struct LogContentView: View {
    let logContent: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .navigationTitle("一键登录日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = logContent
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
