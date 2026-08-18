import Foundation

/// Base64 / base64url 工具(与 web/src/crypto/util.ts 语义一致)。
enum B64 {
    /// 标准 base64(带填充, + / )
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func decode(_ s: String) -> Data? {
        Data(base64Encoded: s)
    }

    /// base64url(URL 安全, 无填充)—— 会话密钥在分享链接 fragment 中使用
    static func encodeUrl(_ data: Data) -> String {
        encode(data)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 解析 base64url → Data(自动补填充)
    static func decodeUrl(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return decode(b)
    }
}
