import XCTest

/// 网络层诊断:模拟器里 App 的 URLSession 访问 chat.linminhao.top 报 TLS error,
/// 而 Safari 正常。对比「默认配置(走系统代理)」vs「绕过代理(connectionProxyDictionary 清空)」。
final class LinMinHaoChatNetworkDiagTests: XCTestCase {

    func testTLSWithSystemProxy() async throws {
        // 与 APIClient 相同的默认配置(会继承系统代理 127.0.0.1:1082)
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: c)
        await probe("默认配置(继承系统代理)", session)
    }

    func testTLSBypassingProxy() async throws {
        // 显式绕过代理:空字典 = 不使用任何代理
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.connectionProxyDictionary = [:]
        let session = URLSession(configuration: c)
        await probe("绕过代理(connectionProxyDictionary=[:])", session)
    }

    func testTLSWithProxyExplicit() async throws {
        // 显式走 127.0.0.1:1082 代理
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        // iOS 无 HTTPS 代理常量:HTTPS 经 CONNECT 隧道复用 HTTP 代理键
        c.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: 1082,
        ]
        let session = URLSession(configuration: c)
        await probe("显式代理 127.0.0.1:1082", session)
    }

    private func probe(_ name: String, _ session: URLSession) async {
        var req = URLRequest(url: URL(string: "https://chat.linminhao.top/api/health")!)
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? "?"
            print("✅ [\(name)] HTTP \(http?.statusCode ?? -1) body=\(body.prefix(80))")
        } catch {
            let ns = error as NSError
            print("❌ [\(name)] \(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("   underlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)")
            }
        }
    }
}
