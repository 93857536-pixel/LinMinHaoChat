import Foundation
import SwiftUI

/// 邀请深链共享状态:HomeView 输入/系统链接 → 生成 InviteRequest → App 路由打开 InviteChatView
@MainActor
final class InviteSession: ObservableObject {
    @Published var pending: InviteRequest?

    struct InviteRequest {
        let inviteId: String
        let sessionKeyB64url: String?
        /// URL query:roomCode=<6位码>(已解析好的直接跳过验证码)
        let roomCode: String?
        /// 是否账号聊天
        let accountMode: Bool
        /// 账号模式下的服务端 token
        let jwt: String?
        let nickname: String?

        init(inviteId: String, sessionKeyB64url: String? = nil,
             roomCode: String? = nil, accountMode: Bool = false,
             jwt: String? = nil, nickname: String? = nil) {
            self.inviteId = inviteId
            self.sessionKeyB64url = sessionKeyB64url
            self.roomCode = roomCode
            self.accountMode = accountMode
            self.jwt = jwt
            self.nickname = nickname
        }
    }
}

/// 解析邀请链接(与 web InviteChat.tsx loadFromUrl 对齐)
enum InviteLinkParser {
    /// 支持:
    ///  https://chat.linminhao.top/i/<id>#k=<b64url>
    ///  https://chat.linminhao.top/i/<id>?account=1&roomCode=AB12CD#k=<b64url>
    ///  短链 https://linminhao.top/t/<id>#k=<b64url>(302 跳转后同上)
    ///  自定义 scheme:lmhchat://invite/<id>#k=...
    static func parse(url: URL, jwt: String?, nickname: String?) -> InviteSession.InviteRequest? {
        let host = url.host() ?? ""
        let path = url.path

        // 从路径提取 invite id: /i/<id> 或 /t/<id> 或 lmhchat://invite/<id>
        let components = path.split(separator: "/").filter { !$0.isEmpty }
        var inviteId: String?
        var accountMode = false
        if let first = components.first {
            if first == "i" || first == "t", components.count >= 2 {
                inviteId = String(components[1])
                // query 里可能有 account=1
                if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    if q.first(where: { $0.name == "account" && $0.value == "1" }) != nil {
                        accountMode = true
                    }
                }
            } else if host == "lmhchat" {
                // lmhchat://invite/<id>
                if first == "invite", components.count >= 2 {
                    inviteId = String(components[1])
                }
            }
        }
        guard let id = inviteId, !id.isEmpty else { return nil }

        // fragment 解析 #k=<b64url>
        var key: String?
        if let frag = url.fragment {
            for part in frag.split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2, String(kv[0]) == "k" {
                    key = decodeB64url(String(kv[1]))
                }
            }
        }

        // roomCode
        var roomCode: String?
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            roomCode = q.first(where: { $0.name == "roomCode" })?.value
        }

        return InviteSession.InviteRequest(
            inviteId: id,
            sessionKeyB64url: key,
            roomCode: roomCode,
            accountMode: accountMode,
            jwt: jwt,
            nickname: nickname
        )
    }

    /// 从分享口令生成链接
    static func makeLink(host: String, inviteId: String, account: Bool,
                         keyB64: String, roomCode: String?) -> String {
        var path = "/i/\(inviteId)"
        var query: [String] = []
        if account { query.append("account=1") }
        if let rc = roomCode { query.append("roomCode=\(rc)") }
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        return "https://\(host)\(path)#k=\(keyB64)"
    }

    static func decodeB64url(_ s: String) -> String? {
        var v = s
        v = v.replacingOccurrences(of: "-", with: "+")
        v = v.replacingOccurrences(of: "_", with: "/")
        while v.count % 4 != 0 { v += "=" }
        guard let d = Data(base64Encoded: v) else { return nil }
        return d.base64EncodedString()
    }

    static func encodeB64url(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: "-")
         .replacingOccurrences(of: "/", with: "_")
         .replacingOccurrences(of: "=", with: "")
    }
}
