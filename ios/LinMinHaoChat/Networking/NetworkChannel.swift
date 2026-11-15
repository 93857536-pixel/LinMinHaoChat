import Foundation
import CryptoKit
import Security

// MARK: - 网络通道配置 (桌面方案 linminhao-chat-双通道直连方案.md)
// 两套可并行的后端端点:
//   domestic: direct.linminhao.top 直连服务器 443 (Let's Encrypt 证书, 国内单跳 30-60ms)
//   intl:     Cloudflare 代理 chat.linminhao.top (现状, 海外 200-500ms)

// MARK: - 通道定义
enum LMHChannel: String, CaseIterable, Identifiable {
    case domestic = "domestic"
    case intl = "intl"

    var id: String { rawValue }

    /// 主域名/主机: 用于 HTTPS/TLS 握手 SNI + Host 头
    var host: String {
        switch self {
        case .domestic: return "direct.linminhao.top" // 直连服务器(LE 受信任证书, 不经 CF)
        case .intl: return "chat.linminhao.top"       // Cloudflare 代理
        }
    }

    /// REST API 基址
    var apiBase: String { "https://\(host)/api" }

    /// WebSocket 基址 (join 接口 wsUrl 为准, 此处为兜底)
    var wsBase: String { "wss://\(host)/ws" }

    /// 显示名 (设置页)
    var displayName: String {
        switch self {
        case .domestic: return "国内直连"
        case .intl: return "国际 CF"
        }
    }
}

// MARK: - 证书 Pinning (内嵌服务器证书 + 设为信任锚)
/// 方案说明:
///   服务器国内直连通道用 10 年期自签证书。iOS 上仅靠 URLSessionDelegate 返回
///   useCredential 不够 —— CFNetwork 仍会对 trust 对象做系统评估并以 -9802 失败
///   (日志: System Trust Evaluation yielded status(-9802))。
///   正确做法: 把证书 DER 内嵌进 App, 在 TLS 挑战时调用
///     SecTrustSetAnchorCertificates(trust, [内置证书]) + SecTrustSetAnchorCertificatesOnly(true)
///     SecTrustEvaluateWithError(trust) == true → useCredential
///   等价于"只信任这一张证书", 防中间人, 且系统评估通过。
///   证书更新时需同步替换下方 base64(openssl x509 -outform DER | base64)。
enum LMHCertPin {
    /// 服务器证书 DER (deploy/lmh-chat-ssl/chat-ip.crt)
    /// CN=linminhao-chat, SAN=IP:112.126.79.9,DNS:chat.linminhao.top, 2026-11-14 ~ 2036-11-11
    /// SHA256(DER) = 1qNJMVUqdN54MF8yNUf4JvnPTcD7iamY/Oxh1EZDMyY=
    static let serverCertBase64 = """
MIIDODCCAiCgAwIBAgIURazZqX3RnWQIIQdRV4LlIFrsIbcwDQYJKoZIhvcNAQELBQAwGTEXMBUGA1UEAwwObGlubWluaGFvLWNoYXQwHhcNMjYxMTE0MTIzMDA0WhcNMzYxMTExMTIzMDA0WjAZMRcwFQYDVQQDDA5saW5taW5oYW8tY2hhdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALOw8cVvSaIstSXDguzxtFincfvSFzwnDZXnoF3nD7cjAGuPAn9ubtZQmXFkMZotdWmQ1z5jHRQU5mfHdnS07dBBw6YtbCeZgnJRMciBj0hLKejpEtfOy2Jx3vUNV1oiVjeGJan31IJ/9v9M4XGvmiU12Kk8e1uI+nN8cdr+/SjwWZCaZ9mq2ITOXbUF0BRxlVRABMp5bTOgus5msTea81VihPVqGc5sujN4/BqVeDXS2GKlyI1uCe4UC6hbQ9gehMD3BefL3Sqd+LCVz5BDAMcd7rbGuBvd8hoIe37yDwO1yby2ozmzQadzxIcYrlROP5irU6cdBMAvniiZl5oTylMCAwEAAaN4MHYwHQYDVR0OBBYEFAPzFDJV68D4XxwFMD1+rq40Ae7BMB8GA1UdIwQYMBaAFAPzFDJV68D4XxwFMD1+rq40Ae7BMA8GA1UdEwEB/wQFMAMBAf8wIwYDVR0RBBwwGocEcH5PCYISY2hhdC5saW5taW5oYW8udG9wMA0GCSqGSIb3DQEBCwUAA4IBAQBG/HrOzb9joYe8JuAKnempVGrYCzGtR4kiXDrl2D/Ws/Ib3b0u3p1vhAA+A0zvEt7nLyBzHtwyThdVveUF0vHtFA0xatYpsZfMRLeNQFLO3/R7VCobVOv8i2q9j+1xrufM80/ostcZBR7ur6WTA2G3xioq1sLSheXpj/9y8xgQyz6z5FrJnj23aGXSb+6qAkp22YtY6aZXYrKZZuCEU1mNoiJTlrc+KBQkkDSV1Akhcie4QyKzVHcJYXw9AUL0/GRysyuwmTn717C+ae0BBTgffioiFucKizqGizuKPGD7EbUyGi8OCsbrRXf+I14FEYNXg0Jh4++yxoEUN8DWx+6b
"""

    /// 内置证书(DER)
    static var serverCert: SecCertificate? {
        guard let der = Data(base64Encoded: serverCertBase64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// 把内置证书设为信任锚并评估; 通过则返回可放行的 trust
    static func validate(_ trust: SecTrust) -> Bool {
        guard let cert = serverCert else { return false }
        // 仅信任内置这一张证书
        guard SecTrustSetAnchorCertificates(trust, [cert] as CFArray) == errSecSuccess else { return false }
        guard SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        return ok
    }

    /// 兜底: 证书链里任一证书的 DER SHA256 命中(证书被替换时立即失败)
    static func hashMatches(_ chain: [SecCertificate]) -> Bool {
        let expected = "1qNJMVUqdN54MF8yNUf4JvnPTcD7iamY/Oxh1EZDMyY="
        for cert in chain {
            let der = SecCertificateCopyData(cert) as Data
            if Data(SHA256.hash(data: der)).base64EncodedString() == expected { return true }
        }
        return false
    }
}

// MARK: - 通道状态机 (全 App 共享)
final class NetworkChannel: ObservableObject {
    static let shared = NetworkChannel()

    enum Mode: String, CaseIterable, Identifiable {
        case auto = "auto"      // 默认: 并发探测, 选更快且可达者
        case domestic = "domestic" // 强制国内直连
        case intl = "intl"       // 强制国际 CF

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "自动"
            case .domestic: return "国内直连"
            case .intl: return "国际 CF"
            }
        }
    }

    @Published var mode: Mode
    @Published var activeChannel: LMHChannel
    @Published var domesticLatencyMs: Int?
    @Published var intlLatencyMs: Int?
    @Published var probing = false
    @Published var channelError: String?

    private let keyMode = "lmh.channel.mode"
    private let keyActive = "lmh.channel.active"
    private let consecutiveFailuresThreshold = 3
    private var consecutiveFailures = 0

    private init() {
        let storedMode = Mode(rawValue: UserDefaults.standard.string(forKey: keyMode) ?? "") ?? .auto
        let storedActive = LMHChannel(rawValue: UserDefaults.standard.string(forKey: keyActive) ?? "") ?? .intl
        mode = storedMode
        activeChannel = (storedMode == .auto) ? storedActive : storedMode.channelFromMode
    }

    // MARK: - 公开 API

    /// 切换模式
    func setMode(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: keyMode)
        switch newMode {
        case .domestic: setActive(.domestic)
        case .intl: setActive(.intl)
        case .auto: Task { await runAutoSelection() }
        }
        channelError = nil
    }

    /// 传输失败钩子 (APIClient / WSClient 调用)
    func noteFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= consecutiveFailuresThreshold, mode == .auto {
            consecutiveFailures = 0
            Task { await runAutoSelection() }
        }
    }

    /// 传输成功钩子
    func noteSuccess() {
        consecutiveFailures = 0
    }

    /// 手动触发重探测
    func reprobe() async {
        if mode == .auto { await runAutoSelection() }
    }

    // MARK: - 私有实现

    private func setActive(_ ch: LMHChannel) {
        activeChannel = ch
        UserDefaults.standard.set(ch.rawValue, forKey: keyActive)
    }

    /// 自动模式: 并发探测两端, 选更快且可达者
    private func runAutoSelection() async {
        guard mode == .auto else { return }
        probing = true
        channelError = nil

        async let d: Int? = probeTimeout(.domestic, timeout: 4)
        async let i: Int? = probeTimeout(.intl, timeout: 4)
        let dv = await d
        let iv = await i

        await MainActor.run {
            self.domesticLatencyMs = dv
            self.intlLatencyMs = iv
            self.probing = false

            let pick: LMHChannel?
            if let dv, let iv { pick = (dv <= iv) ? .domestic : .intl }
            else if dv != nil { pick = .domestic }
            else if iv != nil { pick = .intl }
            else { pick = nil }

            if let p = pick { self.setActive(p) }
        }
    }

    /// 探活: GET /healthz (nginx 443 与 CF 都提供), 返回毫秒延迟; 不可达返回 nil
    private func probeTimeout(_ ch: LMHChannel, timeout: TimeInterval) async -> Int? {
        guard let url = URL(string: "https://\(ch.host)/healthz") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        // ⚠️ 必须禁用 HTTP/3(QUIC): QUIC 的证书校验不走 URLSessionDelegate 的认证挑战,
        //    自签证书在国内直连通道上会直接被系统拒绝(-9802)且不给我们 pin 的机会。
        //    强制走 TCP/TLS 后由 PinnedTrust 按证书指纹放行。
        if #available(iOS 14.0, *) { req.assumesHTTP3Capable = false }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 1

        let session: URLSession
        if ch == .domestic {
            session = URLSession(configuration: cfg, delegate: PinnedTrustDelegate.shared, delegateQueue: nil)
        } else {
            session = URLSession(configuration: cfg)
        }
        let t0 = Date()
        defer { session.invalidateAndCancel() }

        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return max(0, Int(Date().timeIntervalSince(t0) * 1000))
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - 证书 Pinning (TLS 挑战处理)
/// 国内直连通道的 TLS 信任评估(按挑战 host 分发, 与当前活动通道解耦):
/// - host = 112.126.79.9: 系统信任链会拒绝自签证书, 只要证书链里任一证书
///   SPKI pin 命中即放行(防中间人: 换成别的自签证书就过不了)
/// - 其余 host: 走系统默认信任链(国际 CF 通道的合法证书)
/// 独立成函数, 可被 APIClient session、WebSocketClient delegate、探测 session 复用。
enum PinnedTrust {
    /// 仅 IP 兜底连接时才需要 pin(自签证书); 域名通道走系统信任链(LE 证书合法)
    static let legacyIPHost = "112.126.79.9"

    static func handleTLSChallenge(_ challenge: URLAuthenticationChallenge,
                                   _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        let method = challenge.protectionSpace.authenticationMethod
        NSLog("[LMHTLS] challenge host=%@ method=%@", host, method)
        guard method == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            NSLog("[LMHTLS] default: no serverTrust")
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard host == legacyIPHost else {
            NSLog("[LMHTLS] default trust chain: %@", host)
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var chain: [SecCertificate] = []
        for idx in 0..<SecTrustGetCertificateCount(trust) {
            if let c = SecTrustGetCertificateAtIndex(trust, idx) { chain.append(c) }
        }
        guard !chain.isEmpty, LMHCertPin.hashMatches(chain) else {
            NSLog("[LMHTLS] CANCEL: cert hash mismatch")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // ⚠️ 不做 SecTrustEvaluateWithError:
        //    自签证书天然"不合规"(有效期 10 年 > Apple 825 天上限、缺 EKU serverAuth),
        //    系统评估必然失败(-67901 → -9802)。而我们已经用证书 DER SHA256 精确锁定了
        //    唯一认可的那张证书 —— 这就是 pinning 的全部意义, 等价强度高于 CA 链校验。
        //    设一下 anchor(不评估)让 CFNetwork 后续内部检查也能过。
        if let cert = LMHCertPin.serverCert {
            SecTrustSetAnchorCertificates(trust, [cert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        NSLog("[LMHTLS] useCredential OK (pinned)")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// APIClient / 探测 session 使用的 URLSessionDelegate: 转发给 PinnedTrust
final class PinnedTrustDelegate: NSObject, URLSessionDelegate {
    static let shared = PinnedTrustDelegate()

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        PinnedTrust.handleTLSChallenge(challenge, completionHandler)
    }
}

// MARK: - Helper 扩展
extension NetworkChannel.Mode {
    var channelFromMode: LMHChannel {
        switch self {
        case .domestic: return .domestic
        case .intl: return .intl
        case .auto: return .intl // 默认先用国际
        }
    }
}
