import SwiftUI

/// 登录 / 注册(手机/邮箱验证码)。
/// 账号聊天功能接线在下一阶段;本页完成验证码发送 + 登录/注册 + 身份密钥上报。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState

    @State private var target = ""          // 手机号或邮箱
    @State private var code = ""
    @State private var handle = ""          // 注册可选昵称
    @State private var isEmail = true
    @State private var isSendingCode = false
    @State private var isSubmitting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if appState.isLoggedIn {
                Section {
                    LabeledContent("状态", value: "已登录(账号聊天功能下一阶段接入)")
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                    }
                }
            } else {
                Section("账号类型") {
                    Picker("验证码通道", selection: $isEmail) {
                        Text("邮箱").tag(true)
                        Text("手机号").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section("登录信息") {
                    TextField(isEmail ? "邮箱地址" : "手机号", text: $target)
                        .keyboardType(isEmail ? .emailAddress : .phonePad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        TextField("6 位验证码", text: $code)
                            .keyboardType(.numberPad)
                        Spacer()
                        Button(isSendingCode ? "发送中…" : "发送验证码") {
                            Task { await sendCode() }
                        }
                        .disabled(target.isEmpty || isSendingCode)
                    }

                    TextField("昵称(注册时可选)", text: $handle)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Button {
                        Task { await submit(register: true) }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("注册")
                        }
                    }
                    .disabled(code.isEmpty || isSubmitting)

                    Button {
                        Task { await submit(register: false) }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("登录")
                        }
                    }
                    .disabled(code.isEmpty || isSubmitting)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }

            Section("隐私说明") {
                Text("验证码仅用于身份验证;登录后本机自动生成加密身份密钥,私钥只存本机 Keychain,服务器仅保存公钥。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("登录 / 注册")
    }

    private var accountType: String { isEmail ? "email" : "sms" }

    private func sendCode() async {
        isSendingCode = true
        errorMessage = nil
        defer { isSendingCode = false }
        do {
            let r = try await AuthAPI.sendCode(type: accountType, target: target)
            statusMessage = "验证码已发送(\(r.expiresInSec) 秒内有效)"
        } catch {
            errorMessage = "发送失败:\(error.localizedDescription)"
        }
    }

    private func submit(register: Bool) async {
        isSubmitting = true
        errorMessage = nil
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
                              userId: r.user.id, handle: r.user.handle)
            statusMessage = "\(register ? "注册" : "登录")成功 ✓"
        } catch {
            errorMessage = "\(register ? "注册" : "登录")失败:\(error.localizedDescription)"
        }
    }
}
