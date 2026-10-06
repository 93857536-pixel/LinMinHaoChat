import CryptoKit
import Foundation

/// API 错误(带 HTTP 状态码;data 为响应 JSON 的顶层字段字典,含 seq/retryAfterSec 等)
struct ApiError: Error, LocalizedError {
    let status: Int
    let message: String
    var data: [String: Any]?

    var errorDescription: String? {
        switch status {
        case 409: return "消息序号冲突,请重试"
        case 429: return "请求过于频繁,请稍后再试"
        case 401, 403: return "未授权或没有权限"
        default: return message.isEmpty ? "请求失败(\(status))" : message
        }
    }
}

/// REST API 客户端 —— 与 web/src/api.ts 对应,统一错误处理。
/// 基址自动指向 https://chat.linminhao.top/api,用户无需也不应知道该地址。
enum APIClient {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    static func url(_ path: String) -> URL {
        URL(string: AppEnvironment.apiBaseURL + path)!
    }

    /// 通用请求。body 为 [String: Any] 时走 JSONSerialization;为 Encodable 时走 JSONEncoder。
    static func request<T: Decodable>(
        _ path: String,
        method: String? = nil,
        body: Any? = nil,
        token: String? = nil
    ) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = method ?? (body != nil ? "POST" : "GET")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let encodable = body as? any Encodable, !(body is [String: Any]) {
                req.httpBody = try JSONEncoder().encode(encodable)
            } else {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    /// 原字节请求(附件上传/下载)
    static func requestData(
        _ path: String,
        method: String = "GET",
        bodyData: Data? = nil,
        contentType: String? = nil,
        token: String? = nil
    ) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.httpBody = bodyData
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await sendRaw(req)
    }

    private static func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data = try await sendRaw(req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 原始字节请求(附件上传/下载)
    static func sendRaw(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ApiError(status: -1, message: "网络错误")
        }
        guard (200...299).contains(http.statusCode) else {
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (dict?["error"] as? String) ?? (dict?["message"] as? String) ?? "请求失败(\(http.statusCode))"
            throw ApiError(status: http.statusCode, message: msg, data: dict)
        }
        return data
    }
}

// MARK: - 登录认证(与 server/src/routes/auth.ts 对齐)

enum AuthAPI {
    struct SendCodeResult: Decodable { let ok: Bool; let expiresInSec: Int }
    struct AuthResult: Decodable {
        let ok: Bool
        struct User: Decodable { let id: Int; let handle: String? }
        let user: User
        let token: String
        let sessionId: String
    }

    /// 发送验证码(手机 or 邮箱统一端点)
    static func sendCode(type: String, target: String) async throws -> SendCodeResult {
        try await APIClient.request("/auth/send-code", body: ["type": type, "target": target])
    }

    /// 注册(验证码登录即注册;可选携带本设备公钥)
    static func register(type: String, target: String, code: String, handle: String?,
                         deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        try await APIClient.request("/auth/register", body: [
            "type": type, "target": target, "code": code, "handle": handle,
            "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub,
        ])
    }

    /// 登录(仅验证码)
    static func login(type: String, target: String, code: String,
                      deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        try await APIClient.request("/auth/login", body: [
            "type": type, "target": target, "code": code,
            "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub,
        ])
    }

    /// 登出:作废当前 session
    static func logout(sessionId: String, token: String) async throws -> Empty {
        try await APIClient.request("/auth/logout", body: ["sessionId": sessionId], token: token)
    }

    /// 号码认证一键登录(SpToken → GetMobile 换号,server /api/pns/phone-check)
    static func phoneCheck(spToken: String, handle: String? = nil,
                           deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        var body: [String: Any] = ["spToken": spToken,
                                   "deviceId": deviceId,
                                   "ed25519Pub": ed25519Pub,
                                   "ecdhPub": ecdhPub]
        if let handle, !handle.isEmpty { body["handle"] = handle }
        let result: AuthResult = try await APIClient.request("/pns/phone-check", body: body)
        return result
    }
}

// MARK: - 密钥管理(与 server/src/routes/keys.ts 对齐)

enum KeysAPI {
    struct KeysBundle: Decodable {
        let ok: Bool
        let keys: [String]   // 我的 wrappedKey 字符串数组(每设备一个,JSON 文本)
    }

    struct UserKeysResult: Decodable {
        let ok: Bool
        struct Device: Decodable {
            let device_id: String
            let ed25519_pub: String
            let ecdh_pub: String
        }
        let devices: [Device]
    }

    /// 上传/更新我的公钥(每设备)
    static func register(token: String) async throws {
        let identity = try IdentityStore.ensure()
        let _: Empty = try await APIClient.request("/keys/register",
            body: ["ed25519Pub": identity.ed25519Pub, "ecdhPub": identity.ecdhPub, "deviceId": identity.deviceId],
            token: token)
    }

    /// 拉取我的房间会话密钥包(仅"我的"设备 wrapped keys)
    static func roomKeys(_ roomId: String, deviceId: String, token: String) async throws -> KeysBundle {
        try await APIClient.request("/chat/rooms/\(roomId)/keys?deviceId=\(deviceId)", token: token)
    }

    /// 追加 wrapped key(群聊邀请新成员 / 新设备加入)
    static func addRoomKey(_ roomId: String, userId: Int, deviceId: String, wrappedKey: String, token: String) async throws -> Empty {
        try await APIClient.request("/chat/rooms/\(roomId)/keys",
                                    body: ["userId": userId, "deviceId": deviceId, "wrappedKey": wrappedKey],
                                    token: token)
    }

    /// 保存加密导出包(仅保留最新一份)
    static func saveExportPackage(pkg: String, deviceId: String, token: String) async throws {
        let _: Empty = try await APIClient.request("/keys/export-package", body: ["pkg": pkg, "deviceId": deviceId], token: token)
    }

    /// 拉取我的加密导出包
    static func getExportPackage(deviceId: String, token: String) async throws -> String? {
        struct R: Decodable { let ok: Bool; let pkg: String? }
        let r: R = try await APIClient.request("/keys/export-package?deviceId=\(deviceId)", token: token)
        return r.pkg
    }

    /// 查询用户公钥(创建会话用;对应 server GET /keys/public/:userId)
    static func getUserKeys(_ userId: Int, token: String) async throws -> UserKeysResult {
        try await APIClient.request("/keys/public/\(userId)", token: token)
    }
}

// MARK: - 临时聊天(与 server/src/routes/temp.ts 对齐)

enum TempAPI {
    struct CreateResult: Decodable { let ok: Bool; let roomId: String; let expiresAt: Int64 }
    struct RoomInfo: Decodable {
        let ok: Bool
        let roomId: String
        let createdAt: Int64
        let expiresAt: Int64
        let expired: Bool
        let status: String
        let messageCount: Int
    }
    struct JoinResult: Decodable { let ok: Bool; let anonId: String; let wsToken: String; let wsUrl: String }
    struct SendResult: Decodable { let ok: Bool; let seq: Int; let id: String; let ts: Int64 }
    struct HistoryResult: Decodable { let ok: Bool; let messages: [TempMsg]; let hasMore: Bool }

    static func create() async throws -> CreateResult {
        try await APIClient.request("/temp/rooms", method: "POST")
    }

    static func info(_ roomId: String) async throws -> RoomInfo {
        try await APIClient.request("/temp/rooms/\(roomId)")
    }

    static func join(_ roomId: String, anonId: String?) async throws -> JoinResult {
        try await APIClient.request("/temp/rooms/\(roomId)/join",
                                    body: anonId.map { ["anonId": $0] } ?? [:]) as JoinResult
    }

    static func send(_ roomId: String, iv: String, cipher: String, anonId: String, seq: Int, ts: Int64, meta: String? = nil) async throws -> SendResult {
        var body: [String: Any] = ["iv": iv, "cipher": cipher, "anonId": anonId, "seq": seq, "ts": ts]
        if let meta { body["meta"] = meta }
        let result: SendResult = try await APIClient.request("/temp/rooms/\(roomId)/messages", body: body)
        return result
    }

    static func history(_ roomId: String, afterSeq: Int = 0, limit: Int = 100) async throws -> HistoryResult {
        try await APIClient.request("/temp/rooms/\(roomId)/messages?afterSeq=\(afterSeq)&limit=\(limit)") as HistoryResult
    }

    static func leave(_ roomId: String) async throws -> Empty {
        try await APIClient.request("/temp/rooms/\(roomId)/leave", method: "POST")
    }
}

// MARK: - 账号聊天(与 server/src/routes/chat.ts 对齐)

enum ChatAPI {
    struct RoomsResult: Decodable {
        let ok: Bool
        let rooms: [RoomMeta]
    }

    struct RoomResult: Decodable {
        let ok: Bool
        let room: RoomMeta
    }

    struct HistoryResult: Decodable {
        let ok: Bool
        let messages: [ChatMsg]
        let hasMore: Bool
    }

    struct CreateResult: Decodable {
        let ok: Bool
        let room: RoomMeta
    }

    struct SendResult: Decodable {
        let ok: Bool
        let seq: Int
        let id: String
        let ts: Int64
    }

    struct MarkReadResult: Decodable {
        let ok: Bool
    }

    struct OnlineResult: Decodable {
        let ok: Bool
        let online: [Int]
    }

    /// 我的房间列表
    static func rooms(token: String) async throws -> RoomsResult {
        try await APIClient.request("/chat/rooms", token: token)
    }

    /// 创建会话(dm/group)。wrappedKeys: [{userId, deviceId, wrappedKey}]
    static func createRoom(type: String, memberIds: [Int], nameEnc: String?, wrappedKeys: [WrappedKeyEntry], token: String) async throws -> CreateResult {
        try await APIClient.request("/chat/rooms", body: [
            "type": type,
            "memberIds": memberIds,
            "nameEnc": nameEnc,
            "wrappedKeys": wrappedKeys,
        ], token: token)
    }

    /// 会话详情
    static func room(_ roomId: String, token: String) async throws -> RoomResult {
        try await APIClient.request("/chat/rooms/\(roomId)", token: token)
    }

    /// 拉取会话密钥包(仅"我的" wrapped keys)
    static func keys(_ roomId: String, deviceId: String, token: String) async throws -> KeysAPI.KeysBundle {
        try await APIClient.request("/chat/rooms/\(roomId)/keys?deviceId=\(deviceId)", token: token)
    }

    /// 追加 wrapped key(群聊新成员 / 新设备)
    static func addKey(_ roomId: String, userId: Int, deviceId: String, wrappedKey: String, token: String) async throws -> Empty {
        try await APIClient.request("/chat/rooms/\(roomId)/keys",
                                    body: ["userId": userId, "deviceId": deviceId, "wrappedKey": wrappedKey],
                                    token: token)
    }

    /// 群聊添加成员
    static func addMember(_ roomId: String, userId: Int, token: String) async throws -> Empty {
        try await APIClient.request("/chat/rooms/\(roomId)/add-member", body: ["userId": userId], token: token)
    }

    /// 发送密文消息
    static func send(_ roomId: String, iv: String, cipher: String, seq: Int, ts: Int64, kind: String, meta: String? = nil, token: String) async throws -> SendResult {
        var body: [String: Any] = ["iv": iv, "cipher": cipher, "seq": seq, "ts": ts, "kind": kind]
        if let meta { body["meta"] = meta }
        let result: SendResult = try await APIClient.request("/chat/rooms/\(roomId)/messages", body: body, token: token)
        return result
    }

    /// 拉取历史密文(分页)
    static func history(_ roomId: String, afterSeq: Int = 0, beforeSeq: Int = 0, limit: Int = 100, token: String) async throws -> HistoryResult {
        var q = "/chat/rooms/\(roomId)/messages?afterSeq=\(afterSeq)&limit=\(limit)"
        if beforeSeq > 0 { q += "&beforeSeq=\(beforeSeq)" }
        let result: HistoryResult = try await APIClient.request(q, token: token)
        return result
    }

    /// 已读回执(元数据)
    static func markRead(_ roomId: String, lastSeq: Int, token: String) async throws -> MarkReadResult {
        try await APIClient.request("/chat/rooms/\(roomId)/read", body: ["lastSeq": lastSeq], token: token)
    }

    /// 在线成员列表
    static func online(_ roomId: String, token: String) async throws -> OnlineResult {
        try await APIClient.request("/chat/rooms/\(roomId)/online", token: token)
    }

    /// 转发消息到其他房间
    static func forward(_ targetRoomId: String, sourceMsgId: String, srcRoomId: String, cipher: String, iv: String, kind: String, meta: String?, token: String) async throws -> SendResult {
        var body: [String: Any] = [
            "sourceMsgId": sourceMsgId,
            "srcRoomId": srcRoomId,
            "cipher": cipher,
            "iv": iv,
            "kind": kind
        ]
        if let meta { body["meta"] = meta }
        body["ts"] = Int64(Date().timeIntervalSince1970 * 1000)
        let result: SendResult = try await APIClient.request("/chat/rooms/\(targetRoomId)/forward", body: body, token: token)
        return result
    }
}

// MARK: - 邀请链接(与 server/src/routes/invite.ts 对齐:链接 + 6 位验证码,密钥走 #fragment)

enum InviteAPI {
    struct CreateResult: Decodable {
        let ok: Bool
        let inviteId: String
        let roomId: String
        let code: String
        let expiresAt: Int64
        let codeExpiresAt: Int64
        let link: String
    }

    struct InfoResult: Decodable {
        let ok: Bool
        let inviteId: String
        let roomId: String
        let codeExpired: Bool
        let roomExpired: Bool
        let roomStatus: String
        let messageCount: Int
        let roomKind: String
    }

    struct JoinResult: Decodable {
        let ok: Bool
        let roomId: String
        let anonId: String
        let displayName: String
        let wsToken: String
        let wsUrl: String
    }

    /// 创建邀请(返回 6 位验证码 + 链接;客户端自行把 #k=<sessionKey> 拼进分享链接)
    static func create() async throws -> CreateResult {
        try await APIClient.request("/invite/create", method: "POST")
    }

    /// 邀请信息(打开链接后检查房间状态)
    static func info(_ inviteId: String) async throws -> InfoResult {
        try await APIClient.request("/invite/\(inviteId)")
    }

    /// 校验验证码 + 加入房间(游客或账号身份)→ 颁发短期 WS 令牌
    static func join(_ inviteId: String, code: String, token: String?, anonId: String?) async throws -> JoinResult {
        var body: [String: Any] = ["code": code]
        if let token, !token.isEmpty { body["token"] = token }
        if let anonId, !anonId.isEmpty { body["anonId"] = anonId }
        let result: InviteAPI.JoinResult = try await APIClient.request("/invite/\(inviteId)/join", body: body)
        return result
    }
}

// MARK: - 好友系统(与 server/src/routes/friends.ts 对齐;脱敏:仅 handle + 掩码号码)
enum FriendsAPI {
    struct Friend: Decodable, Identifiable, Hashable {
        let userId: Int
        let handle: String
        let phoneMasked: String?
        let emailMasked: String?
        let addedAt: Int64
        let initiator: String   // "mine" | "theirs"
        var id: Int { userId }
    }

    struct SearchUser: Decodable, Identifiable, Hashable {
        let userId: Int
        let handle: String
        let phoneMasked: String?
        let emailMasked: String?
        var isFriend: Bool   // var:搜索后本地乐观更新(添加成功即翻 true)
        var id: Int { userId }
    }

    struct FriendsResult: Decodable {
        let ok: Bool
        let friends: [Friend]
    }

    struct SearchResult: Decodable {
        let ok: Bool
        let users: [SearchUser]
    }

    /// 我的好友列表
    static func list(token: String) async throws -> [Friend] {
        let result: FriendsResult = try await APIClient.request("/friends", token: token)
        return result.friends
    }

    /// 搜索用户(handle 模糊 / 掩码号码末 4 位;全数字 ≥4 位按号码搜)
    static func search(_ query: String, token: String) async throws -> [SearchUser] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let result: SearchResult = try await APIClient.request("/friends/search?query=\(q)", token: token)
        return result.users
    }

    /// 添加好友(双向互加,幂等)
    static func add(_ userId: Int, token: String) async throws {
        let body: [String: Any] = ["userId": userId]
        let _: Empty = try await APIClient.request("/friends", method: "POST", body: body, token: token)
    }

    /// 移除好友(幂等)
    static func remove(_ userId: Int, token: String) async throws {
        let _: Empty = try await APIClient.request("/friends/\(userId)", method: "DELETE", token: token)
    }
}

// MARK: - 附件
enum AttachmentAPI {
    struct UploadResult: Decodable {
        let ok: Bool
        let attId: String
        let size: Int
    }

    /// 上傳加密附件
    static func upload(roomId: String, mimeType: String, data: Data, token: String) async throws -> UploadResult {
        let path = "/attachments?roomId=\(roomId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&declaredMime=\(mimeType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let bytes = try await APIClient.requestData(path, method: "POST", bodyData: data, contentType: "application/octet-stream", token: token)
        return try JSONDecoder().decode(UploadResult.self, from: bytes)
    }
    
    /// 下載加密附件
    static func download(attId: String, token: String) async throws -> Data {
        let path = "/attachments/\(attId)"
        return try await APIClient.requestData(path, method: "GET", token: token)
    }
}

// 服务器成功但不返回 body 的响应
struct Empty: Decodable {}
