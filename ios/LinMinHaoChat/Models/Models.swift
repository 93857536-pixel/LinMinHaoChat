import CryptoKit
import Foundation

/// 临时聊天消息(服务器存储形态,密文)
struct TempMsg: Decodable {
    let id: String
    let seq: Int
    let anonId: String?
    let ts: Int64
    let iv: String
    let aad: String
    let meta: String?
    let cipher: String
}

/// 账号聊天消息(服务器存储形态,密文)
struct ChatMsg: Decodable {
    let id: String
    let seq: Int
    let senderId: Int?
    let ts: Int64
    let iv: String
    let aad: String
    let kind: String
    let meta: String?
    let cipher: String
}

/// 房间元数据(账号聊天)
struct RoomMeta: Decodable {
    let id: String
    let type: String          // dm | group
    let nameEnc: String?
    let createdAt: Int64
    let memberIds: [Int]
    let unread: Int
    let lastSeq: Int
}

/// 解密后的展示消息
struct DecryptedMsg: Identifiable, Equatable {
    let id: String
    let seq: Int
    let label: String      // 发送者标签(访客NNN / 账号N / 我)
    let mine: Bool
    let text: String
    let ts: Int64
    let kind: String       // msg | attachment
}

/// 临时聊天会话上下文
struct TempRoomSession: Hashable {
    let roomId: String
    let sessionKey: SymmetricKey
    let isCreator: Bool

    static func == (l: TempRoomSession, r: TempRoomSession) -> Bool {
        l.roomId == r.roomId && l.isCreator == r.isCreator
            && SessionKeyUtil.b64url(l.sessionKey) == SessionKeyUtil.b64url(r.sessionKey)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(roomId)
        hasher.combine(isCreator)
        hasher.combine(SessionKeyUtil.b64url(sessionKey))
    }
}

/// 访客标签 —— 与 web labelFor 完全一致:
/// g{n}→访客NNN(3位补零)、u{n}→账号N、旧随机串→确定性散列(100+h%900)
enum LabelUtil {
    static func label(for anonId: String?) -> String {
        guard let a = anonId, !a.isEmpty else { return "访客" }
        if a.hasPrefix("g"), let n = Int(a.dropFirst()) {
            return String(format: "访客%03d", n)
        }
        if a.hasPrefix("u"), let n = Int(a.dropFirst()) {
            return "账号\(n)"
        }
        // 确定性散列:与 web 相同算法 h = h*31 + charCode, >>> 0
        var h: UInt32 = 0
        for byte in a.utf8 {
            h = h &* 31 &+ UInt32(byte)
        }
        return "访客\(100 + Int(h % 900))"
    }
}

/// 时间工具
enum TimeUtil {
    /// 毫秒时间戳(与 web Date.now() 对齐)
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func formatTime(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
