import SwiftUI

/// 发现 Tab —— 把非高频入口(临时聊天 / 创建邀请 / 加入邀请)集中收纳,
/// 复用现有 TempRoomView / InviteCreateSheet,不改底层功能。
struct DiscoverTab: View {
    struct JoinTarget: Identifiable {
        var id: String { inviteId }
        let inviteId: String
        let key: String?
    }

    @EnvironmentObject private var appState: AppState
    @State private var showTempChat = false
    @State private var showInviteCreate = false
    @State private var joinLink = ""
    @State private var joinTarget: JoinTarget?
    // 服务器延迟检测(「其他」分组):对 /health 多次 HTTP 往返取平均,评估当前网络到服务器的延迟
    @State private var serverLatencyMs: Int?
    @State private var measuringLatency = false

    var body: some View {
        NavigationStack {
            List {
                Section("临时聊天") {
                    Button {
                        showTempChat = true
                    } label: {
                        HStack(spacing: 14) {
                            iconBadge(system: "bolt.fill", color: .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("临时聊天")
                                    .font(.body)
                                Text("发起 / 加入分享链接,刷新即焚,无需登录")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showInviteCreate = true
                    } label: {
                        HStack(spacing: 14) {
                            iconBadge(system: "envelope.badge", color: .blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("创建邀请聊天")
                                    .font(.body)
                                Text("生成链接 + 6 位验证码,记录长期保留(1 年)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("加入邀请聊天")
                            .font(.body)
                        TextField("粘贴邀请链接(含 #k= 密钥)", text: $joinLink, axis: .vertical)
                            .lineLimit(1...3)
                            .lmhInput()
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("加入") {
                            openInviteLink()
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .disabled(joinLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("邀请链接需在 App 内粘贴打开(系统链接跳转也支持,见「我的」)。")
                }

                Section {
                    LabeledContent("后端服务", value: appState.isConnected ? "已连接" : "网络断开")
                    LabeledContent("连接状态", value: appState.connectionStatus.rawValue)
                    HStack(spacing: 10) {
                        Label("服务器延迟", systemImage: "timer")
                        Spacer()
                        if measuringLatency {
                            ProgressView()
                        } else if let ms = serverLatencyMs {
                            Text(ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000.0))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(latencyTone)
                        } else {
                            Button("检测延迟") { measureServerLatency() }
                                .font(.subheadline)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { measureServerLatency() }
                } header: {
                    Text("其他")
                } footer: {
                    if let ms = serverLatencyMs {
                        Text("上次检测:\(msText(ms)),对 /health 连续 3 次往返取平均,点击「服务器延迟」行可重新测量。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showTempChat) {
                NavigationStack {
                    TempRoomView()
                        .environmentObject(appState)
                }
            }
            .sheet(isPresented: $showInviteCreate) {
                InviteCreateSheet()
            }
            .fullScreenCover(item: $joinTarget) { target in
                InviteChatView(inviteId: target.inviteId, sessionKeyB64url: target.key)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: 粘贴加入(解析 #k= 密钥 fragment,复用 InviteLinkParser)
    private func openInviteLink() {
        let trimmed = joinLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        // 支持完整 https 链接与裸 id;密钥从 #k= 提取
        if let req = InviteLinkParser.parse(url: url, jwt: appState.authToken, nickname: appState.userHandle) {
            joinTarget = JoinTarget(inviteId: req.inviteId, key: req.sessionKeyB64url)
        } else {
            // 裸 id 兜底:直接当 inviteId,密钥留空(创建者本机可恢复)
            joinTarget = JoinTarget(inviteId: trimmed, key: nil)
        }
    }

    private func iconBadge(system: String, color: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 服务器延迟检测
    /// 延迟配色:<150ms 绿,<400ms 橙,否则红
    private var latencyTone: Color {
        guard let ms = serverLatencyMs else { return .primary }
        if ms < 150 { return .green }
        if ms < 400 { return .orange }
        return .red
    }

    private func msText(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000.0)
    }

    /// 对 /health 连测 3 次 HTTP 往返取平均(排除首次冷连接,跳过第 1 次),评估到服务器延迟
    private func measureServerLatency() {
        guard !measuringLatency else { return }
        measuringLatency = true
        serverLatencyMs = nil
        Task { @MainActor in
            var samples: [Int] = []
            for _ in 0..<3 {
                let t0 = Date()
                do {
                    struct HealthResult: Decodable { let ok: Bool }
                    let _: HealthResult = try await APIClient.request("/health")
                    samples.append(max(0, Int(Date().timeIntervalSince(t0) * 1000)))
                } catch {
                    // 单次失败不中断,记一个大值拉高平均以提示网络差
                    samples.append(max(0, Int(Date().timeIntervalSince(t0) * 1000)))
                }
            }
            // 去掉最快一帧冷启动影响:3 个样本取后 2 个平均(即跳过 min)
            let avg: Int
            if samples.count == 3 {
                let sorted = samples.sorted()
                avg = Int((Double(sorted[1]) + Double(sorted[2])) / 2.0)
            } else if !samples.isEmpty {
                avg = samples.reduce(0, +) / samples.count
            } else {
                avg = 0
            }
            serverLatencyMs = avg
            measuringLatency = false
        }
    }
}
