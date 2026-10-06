import CryptoKit
import Foundation

// MARK: - 设备身份标识
struct DeviceIdentity {
    let deviceId: String
    let ed25519Pub: String
    let ecdhPub: String
}

// MARK: - 账号聊天会话模型
struct ChatRoomSession: Identifiable {
    let id: String  // roomId
    let roomId: String
    let token: String
    let identity: DeviceIdentity
}

// MARK: - 身份与密钥管理
struct WrappedKeyEntry: Encodable {
    let userId: Int
    let deviceId: String
    let wrappedKey: String
}

// MARK: - 临时聊天消息(服务器存储形态，密文)
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

// MARK: - 账号聊天消息(服务器存储形态，密文)
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

// MARK: - 房间元数据(账号聊天)
struct RoomMeta: Decodable, Identifiable {
    let id: String
    let type: String          // dm | group
    let nameEnc: String?
    let createdAt: Int64
    let memberIds: [Int]
    var unread: Int          // 可本地改写(左滑「标记已读」清未读徽章)
    let lastSeq: Int
}

// MARK: - 解密后的展示消息
struct DecryptedMsg: Identifiable, Equatable {
    let id: String
    let seq: Int
    let label: String      // 发送者标签(访客NNN / 账号N / 我)
    let mine: Bool
    let text: String
    let ts: Int64
    let kind: String       // msg | attachment
    var att: AttachmentInfo?
    var isRead: Bool = false

    
    struct AttachmentInfo: Equatable {
        let attId: String
        let name: String
        let size: Int
        let mime: String
        let duration: Int?  // 语音消息时长(ms)
        
        init(attId: String, name: String, size: Int, mime: String, duration: Int? = nil) {
            self.attId = attId
            self.name = name
            self.size = size
            self.mime = mime
            self.duration = duration
        }
    }
    
    static func == (lhs: DecryptedMsg, rhs: DecryptedMsg) -> Bool {
        lhs.id == rhs.id && lhs.seq == rhs.seq
    }
}

// MARK: - 访客标签工具
enum LabelUtil {
    static func label(for anonId: String?) -> String {
        guard let a = anonId, !a.isEmpty else { return "访客" }
        if a.hasPrefix("g"), let n = Int(a.dropFirst()) {
            return String(format: "访客%03d", n)
        }
        if a.hasPrefix("u"), let n = Int(a.dropFirst()) {
            return "账号\(n)"
        }
        // 确定性散列:与 web 相同算法
        var h: UInt32 = 0
        for byte in a.utf8 {
            h = h &* 31 &+ UInt32(byte)
        }
        return "访客\(100 + Int(h % 900))"
    }
}

// MARK: - 临时聊天会话模型
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

// MARK: - 时间工具
enum TimeUtil {
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    
    static func formatTime(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 聊天列表时间:今天→HH:mm;7 天内→周几;更早→MM-dd
    static func formatListTime(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let now = Date()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return TimeUtil.formatTime(ms)
        }
        if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            f.locale = Locale(identifier: "zh_CN")
            return f.string(from: d)
        }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
    
    static func formatRelative(_ ms: Int64) -> String {
        let now = nowMs
        let diff = now - ms
        if diff < 60_000 { return "刚刚" }
        if diff < 3600_000 { return "\(Int(diff / 60_000))分钟前" }
        if diff < 86400_000 { return "\(Int(diff / 3600_000))小时前" }
        return "\(Int(diff / 86400_000))天前"
    }
}
