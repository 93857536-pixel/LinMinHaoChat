import CryptoKit
import Foundation

/// 会话密钥(32B)生命周期 —— 与 web/src/crypto/session.ts 对应。
///
/// 临时聊天:创建者生成 32B 随机 sessionKey,直接放进分享链接 fragment(`#k=`),
/// fragment 不经过服务器(nginx 日志/后端均不可见)。
enum SessionKeyUtil {
    static func generate() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// 32B → base64url(无填充)
    static func b64url(_ key: SymmetricKey) -> String {
        B64.encodeUrl(keyData(key))
    }

    /// base64url → SymmetricKey
    static func fromB64url(_ s: String) -> SymmetricKey? {
        guard let d = B64.decodeUrl(s), d.count == 32 else { return nil }
        return SymmetricKey(data: d)
    }

    /// 生成临时聊天分享链接(与 web buildTempShareUrl 同构):
    /// https://linminhao.top/t/<roomId>#k=<b64url>
    static func shareUrl(roomId: String, key: SymmetricKey) -> String {
        "https://\(AppEnvironment.host)/t/\(roomId)#k=\(b64url(key))"
    }

    /// 从分享链接解析 (roomId, sessionKey)。支持:
    /// - https://linminhao.top/t/<roomId>#k=... (标准)
    /// - 任意主机路径(自部署/本地) —— 只取 path 最后一段 + fragment
    static func parseShareURL(_ url: URL) -> (roomId: String, key: SymmetricKey)? {
        guard let fragment = url.fragment, fragment.hasPrefix("k=") else { return nil }
        guard let key = fromB64url(String(fragment.dropFirst(2))) else { return nil }
        let roomId = url.path.split(separator: "/").last.map(String.init) ?? ""
        guard !roomId.isEmpty else { return nil }
        return (roomId, key)
    }
}
