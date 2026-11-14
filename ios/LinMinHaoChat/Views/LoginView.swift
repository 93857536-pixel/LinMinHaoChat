import SwiftUI

/// 登录 / 注册(手机/邮箱验证码)。
/// 账号聊天功能接线在下一阶段;本页完成验证码发送 + 登录/注册 + 身份密钥上报。
/// 自定义卡片式布局(不用 Form):输入行之间用清晰的 Divider 分隔,深浅色模式都可见。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 进入时偏向的按钮模式:false=登录(默认) / true=注册。
    /// 首页「登录」「注册」两个入口各自打开对应模式,页内可小字切换。
    @State private var isRegisterMode: Bool
    @State private var target = ""          // 手机号或邮箱
    @State private var code = ""
    @State private var handle = ""          // 注册可选昵称
    @State private var isEmail = true
    /// 登录流程进行中(防止 dismiss 动画期间渲染出「已登录」卡片)
    @State private var isAuthPending = false

    init(preferRegister: Bool = false) {
        _isRegisterMode = State(initialValue: preferRegister)
    }
    @State private var isSendingCode = false
    @State private var countdown = 0        // 发送验证码冷却倒计时(秒),防连点触发 otp 限流
    @State private var isSubmitting = false
    @State private var isPNSLogin = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    /// 一键登录环境探测:真机 + 蜂窝/SIM 才可用。模拟器/无 SIM 环境直接置灰,
    /// 避免用户点了按钮只有中间一行小字提示、误以为「没反应」(2026-09 模拟器实测 600007 无SIM卡)。
    private var oneTapUnavailable: Bool {
        // 模拟器检测:Apple 给模拟器进程注入 SIMULATOR_DEVICE_NAME 环境变量
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
    }

    /// 一键登录环境检测文案
    private var oneTapUnavailableReason: String {
        // 根据当前错误状态返回更详细的提示
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            return "当前在模拟器上运行，一键登录需要在真机上使用，请改用验证码登录"
        }
        return "一键登录需要 SIM 卡 + 蜂窝网络，当前环境不可用，请改用验证码登录"
    }

    private var countdownTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if appState.isLoggedIn && !isAuthPending {
                    loggedInCard
                } else {
                    accountTypePicker
                    inputCard
                    actionButtons
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                privacyFooter
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isRegisterMode ? "注册" : "登录")
        .navigationBarTitleDisplayMode(.inline)
        // 进登录页/切账号类型时后台预取号(accelerateLoginPage),授权页秒弹;
        // 真机+蜂窝环境才有意义,模拟器自动跳过(oneTapUnavailable)
        .task(id: isEmail) { await prepareOneTap() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if countdown > 0 { countdown -= 1 }
        }
    }

    // MARK: - 账号类型选择

    private var accountTypePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账号类型")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("验证码通道", selection: $isEmail) {
                Text("邮箱").tag(true)
                Text("手机号").tag(false)
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入卡片(自定义分隔线,清晰可见)

    private var inputCard: some View {
        VStack(spacing: 0) {
            TextField(isEmail ? "邮箱地址" : "手机号", text: $target)
                .keyboardType(isEmail ? .emailAddress : .phonePad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(minHeight: 46)

            clearDivider

            HStack {
                TextField("6 位验证码", text: $code)
                    .keyboardType(.numberPad)
                Spacer()
                Button {
                    Task { await sendCode() }
                } label: {
                    if isSendingCode {
                        ProgressView().frame(width: 70)
                    } else if countdown > 0 {
                        Text("重新发送(\(countdown)s)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    } else {
                        Text("发送验证码")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
                .disabled(target.isEmpty || isSendingCode || countdown > 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(minHeight: 46)

            clearDivider

            TextField("昵称(注册时可选)", text: $handle)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(minHeight: 46)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
    }

    private var clearDivider: some View {
        Divider()
            .overlay(Color(.separator))
            .padding(.leading, 14)
    }

    // MARK: - 操作按钮

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // 一键登录(仅手机号模式显示;需要蜂窝网络 + SIM 卡)
            if !isEmail {
                if oneTapUnavailable {
                    // 模拟器/无 SIM 环境:按钮置灰 + 明确提示,避免"点了没反应"
                    Button {
                    } label: {
                        Text("本机号码一键登录")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(true)
                    Text(oneTapUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    Button {
                        Task { await pnsLogin() }
                    } label: {
                        if isPNSLogin {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
                        } else {
                            Text("本机号码一键登录")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(isPNSLogin || isSubmitting)
                }
            }

            // 主按钮跟随入口模式(首页「登录」「注册」分两个入口进来),
            // 另一模式用次级小按钮切换,避免「登录/注册」混在一个按钮里
            if isRegisterMode {
                Button {
                    Task { await submit(register: true) }
                } label: {
                    if isSubmitting {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
                    } else {
                        Text("注册").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.isEmpty || isSubmitting)

                Button {
                    Task { await submit(register: false) }
                } label: {
                    Text("已有账号?去登录").font(.footnote)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(code.isEmpty || isSubmitting)
            } else {
                Button {
                    Task { await submit(register: false) }
                } label: {
                    if isSubmitting {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
                    } else {
                        Text("登录").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.isEmpty || isSubmitting)

                Button {
                    Task { await submit(register: true) }
                } label: {
                    Text("新账号?去注册").font(.footnote)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(code.isEmpty || isSubmitting)
            }
        }
    }

    // MARK: - 已登录卡片

    private var loggedInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("状态", value: "已登录(账号聊天功能下一阶段接入)")
            Divider()
            // ⚠️ 全 App 只保留一处退出登录(我的 → 账号与安全),此处不再放置登出按钮
            Text("需要退出登录?请到「我的 → 账号与安全」中操作。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 隐私说明

    private var privacyFooter: some View {
        Text("验证码仅用于身份验证;登录后本机自动生成加密身份密钥,私钥只存本机 Keychain,服务器仅保存公钥。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    // MARK: - 逻辑

    private var accountType: String { isEmail ? "email" : "sms" }

    private func sendCode() async {
        guard countdown == 0 else { return }
        isSendingCode = true
        errorMessage = nil
        defer { isSendingCode = false }
        do {
            let r = try await AuthAPI.sendCode(type: accountType, target: target)
            countdown = 60  // 冷却 60 秒,防止连点触发服务器 otp 限流(同目标 5 次/小时)
            statusMessage = "验证码已发送(\(r.expiresInSec) 秒内有效)"
        } catch {
            if let e = error as? ApiError, e.status == 429 {
                let retry = e.data?["retryAfterSec"] as? Int ?? 60
                countdown = min(max(retry, 10), 600)
                errorMessage = "发送过于频繁,请 \(countdown) 秒后再试"
            } else {
                errorMessage = "发送失败:\(error.localizedDescription)"
            }
        }
    }

    private func submit(register: Bool) async {
        isSubmitting = true
        errorMessage = nil
        isAuthPending = true
        defer { isSubmitting = false }
        do {
            let identity = try IdentityStore.ensure()
            let r: AuthAPI.AuthResult
            if register {
                r = try await AuthAPI.register(type: accountType, target: target, code: code,
                                               handle: handle.isEmpty ? nil : handle,
                                               deviceId: identity.deviceId,
                                               ed25519Pub: identity.ed25519Pub,
                                               ecdhPub: identity.ecdhPub)
            } else {
                r = try await AuthAPI.login(type: accountType, target: target, code: code,
                                            deviceId: identity.deviceId,
                                            ed25519Pub: identity.ed25519Pub,
                                            ecdhPub: identity.ecdhPub)
            }
            // 上报本设备公钥,其他设备才能把会话密钥包装给我们
            try await KeysAPI.register(token: r.token)
            appState.saveAuth(token: r.token, sessionId: r.sessionId,
                              userId: r.user.id, handle: r.user.handle, nickname: r.user.nickname,
                              phoneMasked: r.user.phoneMasked, emailMasked: r.user.emailMasked)
            // 注册成功后明确告知系统分配的规范账号 ID(不可改);完成后立即关闭登录页回主页
            if register, let h = r.user.handle {
                statusMessage = "注册成功 ✓ 账号 ID:\(h)"
            } else {
                statusMessage = "\(register ? "注册" : "登录")成功 ✓"
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                isAuthPending = false
                dismiss()
            }
        } catch {
            if let e = error as? ApiError, e.status == 429 {
                errorMessage = "请求过于频繁,请稍后再试"
            } else {
                errorMessage = "\(register ? "注册" : "登录")失败:\(error.localizedDescription)"
            }
            isAuthPending = false
        }
    }

    /// 本机号码一键登录:SDK 弹授权页 → SpToken → 服务端换号登录
    private func pnsLogin() async {
        isPNSLogin = true
        isAuthPending = true
        errorMessage = nil
        statusMessage = nil
        defer { isPNSLogin = false }

        // 初始化 SDK(幂等)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PNSAuthManager.shared.setupIfNeeded { _ in cont.resume() }
        }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = windowScene.keyWindow?.rootViewController else {
            errorMessage = "无法获取当前界面,请重试"
            return
        }

        // 沿 presentedViewController 链取最顶层 VC:LoginView 现在是 sheet(fullScreen 或页面内 sheet),
        // 授权页必须从当前最顶层可呈现的控制器弹出;传 rootViewController(被 sheet 盖住)
        // 会被 UIKit 拒绝 present → SDK 报 600002「授权页唤起失败」。
        var topController = root
        while let presented = topController.presentedViewController {
            topController = presented
        }

        let result = await withCheckedContinuation { (cont: CheckedContinuation<PNSLoginResult, Never>) in
            PNSAuthManager.shared.startOneTapLogin(from: topController) { r in cont.resume(returning: r) }
        }

        switch result {
        case .userCancel:
            // 用户返回/切换 → 回退验证码登录,不报错
            statusMessage = "已切换到验证码登录"
        case .notSupported(let reason):
            errorMessage = reason
        case .failed(let reason):
            errorMessage = reason
        case .success(let spToken):
            do {
                let identity = try IdentityStore.ensure()
                let r = try await AuthAPI.phoneCheck(spToken: spToken,
                                                     deviceId: identity.deviceId,
                                                     ed25519Pub: identity.ed25519Pub,
                                                     ecdhPub: identity.ecdhPub)
                try await KeysAPI.register(token: r.token)
                appState.saveAuth(token: r.token, sessionId: r.sessionId,
                                  userId: r.user.id, handle: r.user.handle, nickname: r.user.nickname,
                                  phoneMasked: r.user.phoneMasked, emailMasked: r.user.emailMasked)
                statusMessage = "一键登录成功 ✓"
                // 登录后直接回主页(0.8s 后 dismiss)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    dismiss()
                }
            } catch {
                if let e = error as? ApiError, e.status == 429 {
                    errorMessage = "请求过于频繁,请稍后再试"
                } else {
                    errorMessage = "登录失败:\(error.localizedDescription)"
                }
            }
        }
    }

    /// 进登录页/手机号模式时后台预取号(官方选调 accelerateLoginPage),
    /// 让后续点「本机号码一键登录」时授权页立即弹出,避免现场取号 3s+ 等待被感知为"没反应"
    private func prepareOneTap() async {
        guard !isEmail, !oneTapUnavailable else { return }
        await PNSAuthManager.shared.setupIfNeeded()
        _ = await PNSAuthManager.shared.accelerateLoginPage()
    }
}
