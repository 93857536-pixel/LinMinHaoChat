import SwiftUI

/// 实名认证:姓名 + 身份证号 二要素核验
///
/// 安全说明(客户端侧):
/// - AppCode 只在服务端,客户端不持有任何核验服务凭证
/// - 身份证号仅随请求发送一次,**不落本地存储**;服务端也只保存掩码与不可逆指纹
/// - 提交前本地先做位数/校验位校验,避免无谓消耗付费配额
struct RealNameView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var idcard = ""
    @State private var submitting = false
    @State private var resultTitle: String?
    @State private var resultDetail: String?
    @State private var resultIsError = false
    @State private var serviceEnabled = true
    @State private var checkingService = true

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedId: String { idcard.trimmingCharacters(in: .whitespaces).uppercased() }
    private var canSubmit: Bool {
        !submitting && Self.isValidName(trimmedName) && Self.isValidIdCard(trimmedId)
    }

    var body: some View {
        NavigationStack {
            Form {
                if appState.realnameVerified {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已完成实名认证")
                                    .font(.headline)
                                if let n = appState.realnameNameMasked {
                                    Text("姓名 \(n)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let ts = appState.realnameVerifiedAt {
                                    Text("认证时间 \(Self.dateText(ts))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                if checkingService {
                    Section { HStack { ProgressView(); Text("检查服务状态…").foregroundStyle(.secondary) } }
                } else if !serviceEnabled {
                    Section {
                        Label("实名认证服务未开通", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        TextField("真实姓名", text: $name)
                            .textContentType(.name)
                            .autocorrectionDisabled()
                        TextField("身份证号(18 位)", text: $idcard)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: idcard) { _, v in
                                // 限制为数字与 X,最长 18 位
                                let filtered = String(v.uppercased().filter { $0.isNumber || $0 == "X" }.prefix(18))
                                if filtered != v { idcard = filtered }
                            }
                    } header: {
                        Text(appState.realnameVerified ? "重新核验" : "填写真实身份信息")
                    } footer: {
                        Text("将与权威数据源比对「姓名 + 身份证号」是否一致。身份证号仅用于本次核验,不会明文保存。")
                    }

                    Section {
                        Button {
                            Task { await submit() }
                        } label: {
                            HStack {
                                Spacer()
                                if submitting { ProgressView().padding(.trailing, 6) }
                                Text(submitting ? "核验中…" : "提交核验").bold()
                                Spacer()
                            }
                        }
                        .disabled(!canSubmit)
                    }

                    if !trimmedId.isEmpty && trimmedId.count == 18 && !Self.isValidIdCard(trimmedId) {
                        Section {
                            Label("身份证号校验位不正确,请检查是否输错", systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let resultTitle {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: resultIsError ? "xmark.circle.fill" : "info.circle.fill")
                                .foregroundStyle(resultIsError ? .red : .green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(resultTitle).font(.subheadline.weight(.semibold))
                                if let resultDetail {
                                    Text(resultDetail).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("实名认证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await loadStatus() }
    }

    // MARK: - 网络

    private func loadStatus() async {
        checkingService = true
        defer { checkingService = false }
        guard let token = appState.authToken else { return }
        do {
            let r = try await RealNameAPI.status(token: token)
            serviceEnabled = r.enabled ?? true
            appState.applyRealname(status: r.status, verified: r.verified,
                                   nameMasked: r.nameMasked, verifiedAt: r.verifiedAt)
        } catch {
            serviceEnabled = true   // 网络异常时不阻塞,提交时再报错
        }
    }

    private func submit() async {
        guard let token = appState.authToken else { return }
        submitting = true
        resultTitle = nil
        resultDetail = nil
        defer { submitting = false }
        do {
            let r = try await RealNameAPI.verify(name: trimmedName, idcard: trimmedId, token: token)
            appState.applyRealname(status: r.status, verified: r.verified,
                                   nameMasked: r.nameMasked, verifiedAt: r.verifiedAt)
            switch r.status {
            case "verified":
                resultIsError = false
                resultTitle = "实名认证通过"
                resultDetail = "姓名与身份证号一致。"
                name = ""
                idcard = ""
            case "no_record":
                resultIsError = true
                resultTitle = "未查询到该身份证记录"
                resultDetail = "该号段可能暂不支持核验,请确认号码无误。"
            default:
                resultIsError = true
                resultTitle = "姓名与身份证号不一致"
                resultDetail = "请核对姓名与身份证号是否填写正确后重试。"
            }
        } catch let e as ApiError {
            resultIsError = true
            resultTitle = "核验未完成"
            resultDetail = Self.friendly(e.message)
        } catch {
            resultIsError = true
            resultTitle = "核验未完成"
            resultDetail = "网络异常,请稍后重试。"
        }
    }

    // MARK: - 本地校验(与服务端 realname-util.ts 保持一致)

    private static let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    private static let checkCodes = Array("10X98765432")

    static func isValidIdCard(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.count == 18 else { return false }
        let c = Array(s)
        guard let prov = Int(String(c[0...1])), (11...82).contains(prov) else { return false }
        guard let y = Int(String(c[6...9])), let m = Int(String(c[10...11])), let d = Int(String(c[12...13])),
              (1...12).contains(m), (1...31).contains(d), y >= 1900 else { return false }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        guard let date = Calendar(identifier: .gregorian).date(from: comps), date <= Date() else { return false }
        var sum = 0
        for i in 0..<17 {
            guard let dv = c[i].wholeNumberValue else { return false }
            sum += dv * weights[i]
        }
        return checkCodes[sum % 11] == c[17]
    }

    static func isValidName(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2, s.count <= 20 else { return false }
        guard let first = s.unicodeScalars.first else { return false }
        let isCJK = (0x4E00...0x9FA5).contains(Int(first.value))
        let isLatin = (first.value >= 65 && first.value <= 90) || (first.value >= 97 && first.value <= 122)
        guard isCJK || isLatin else { return false }
        return s.unicodeScalars.allSatisfy { sc in
            let v = Int(sc.value)
            if (0x4E00...0x9FA5).contains(v) { return true }
            if (65...90).contains(v) || (97...122).contains(v) { return true }
            if v == 32 || v == 0x00B7 || v == 0x2022 || v == 46 { return true }
            return false
        }
    }

    private static func friendly(_ raw: String) -> String {
        switch raw {
        case "bad_name": return "姓名格式不正确(2~20 字,需为中文或字母)"
        case "bad_idcard": return "身份证号不正确,请检查位数与校验位"
        case "too_frequent": return "操作过于频繁,请 10 秒后重试"
        case "daily_limit": return "今日核验次数已达上限,请明日再试"
        case "rate_limited": return "请求过于频繁,请稍后再试"
        case "upstream_error": return "核验服务暂时不可用,请稍后再试"
        case "vendor_quota": return "核验服务额度不足,请联系管理员"
        case "vendor_disabled": return "核验服务已停用"
        case "realname_unavailable": return "实名认证服务未开通"
        case "idcard_already_bound": return "该身份证已绑定其他账号(一个身份证只能认证一个账号)"
        default: return raw
        }
    }

    private static func dateText(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
