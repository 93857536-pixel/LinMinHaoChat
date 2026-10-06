import CryptoKit
import Foundation

/// API 错误(带 HTTP 状态码与服务器返回的 error 字段)
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

    private static func sendRaw(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ApiError(status: -1, message: "网络错误")
        }
        guard (200...299).contains(http.statusCode) else {
            do {
                let err = try JSONDecoder().decode(ApiErrorResult.self, from: data)
                throw ApiError(status: http.statusCode, message: err.error ?? err.message ?? "请求失败", data: err.data)
            } catch {
                throw ApiError(status: http.statusCode, message: String(data: data, encoding: .utf8) ?? "请求失败")
            }
        }
        return data
    }

    struct ApiErrorResult: Decodable {
        let ok: Bool?
        let error: String?
        let message: String?
        var data: [String: Any]?

        private enum CodingKeys: String, CodingKey {
            case ok, error, message, data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            // data 字段可能是任意 JSON 对象，用嵌套解码器解析
            data = nil
        }
    }
}

// MARK: - 登录认证

enum AuthAPI {
    struct SendCodeResult: Decodable { let ok: Bool; let expiresInSec: Int }
    struct AuthResult: Decodable {
        let ok: Bool
        struct User: Decodable { let id: Int; let handle: String? }
        let user: User
        let token: String
        let sessionId: String
        let expiresIn: Int
    }

    static func sendCode(type: String, target: String) async throws -> SendCodeResult {
        if type == "email" {
            _ = try await APIClient.request("/auth/send-email-code", body: ["email": target], token: nil) as Empty
            // 返回 dummy result，实际结果在 email 发送时
            return SendCodeResult(ok: true, expiresInSec: 300)
        } else {
            _ = try await APIClient.request("/auth/send-code", body: ["phone": target], token: nil) as Empty
            return SendCodeResult(ok: true, expiresInSec: 300)
        }
    }

    static func login(type: String, target: String, code: String, deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        if type == "email" {
            try await APIClient.request("/auth/login-email", body: ["email": target, "code": code, "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub])
        } else {
            try await APIClient.request("/auth/login-phone", body: ["phone": target, "code": code, "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub])
        }
    }

    static func register(type: String, target: String, code: String, handle: String?, deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        if type == "email" {
            try await APIClient.request("/auth/register", body: ["email": target, "code": code, "handle": handle, "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub])
        } else {
            try await APIClient.request("/auth/register", body: ["phone": target, "code": code, "handle": handle, "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub])
        }
    }

    static func verifyPns(token: String) async throws -> Empty {
        try await APIClient.request("/auth/pns", method: "POST", body: ["token": token])
    }

    static func logout(token: String) async throws -> Empty {
        try await APIClient.request("/auth/logout", token: token)
    }

    static func phoneCheck(spToken: String, deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        try await APIClient.request("/auth/pns-check", body: [
            "spToken": spToken,
            "deviceId": deviceId,
            "ed25519Pub": ed25519Pub,
            "ecdhPub": ecdhPub
        ])
    }
}

// MARK: - 密钥管理

enum KeysAPI {
    struct KeysResult: Decodable {
        let ok: Bool
        struct Device: Decodable {
            let device_id: String
            let ed25519_pub: String
            let ecdh_pub: String
        }
        let devices: [Device]
    }

    struct UserLookupResult: Decodable {
        let ok: Bool
        let devices: [KeysResult.Device]
    }

    static func register(token: String) async throws {
        let identity = try IdentityStore.ensure()
        let _: Empty = try await APIClient.request("/keys/register",
            body: ["ed25519Pub": identity.ed25519Pub, "ecdhPub": identity.ecdhPub, "deviceId": identity.deviceId],
            token: token)
    }

    static func getExportPackage(deviceId: String, token: String) async throws -> String? {
        struct R: Decodable { let ok: Bool; let pkg: String? }
        let r: R = try await APIClient.request("/keys/export-package?deviceId=\(deviceId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? deviceId)", token: token)
        return r.pkg
    }

    static func saveExportPackage(pkg: String, deviceId: String, token: String) async throws {
        let _: Empty = try await APIClient.request("/keys/export-package", body: ["pkg": pkg, "deviceId": deviceId], token: token)
    }
    
    static func keys(_ roomId: String, deviceId: String, token: String) async throws -> KeysResult {
        try await APIClient.request("/chat/rooms/\(roomId)/keys?deviceId=\(deviceId)", token: token)
    }
    
    static func getUserKeys(_ userId: Int, token: String) async throws -> UserLookupResult {
        try await APIClient.request("/keys/user/\(userId)", token: token)
    }
}

// MARK: - 临时聊天

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
                                    body: anonId.map { ["anonId": $0] } ?? [:])
    }

    static func send(_ roomId: String, iv: String, cipher: String, anonId: String, seq: Int, ts: Int64) async throws -> SendResult {
        try await APIClient.request("/temp/rooms/\(roomId)/messages",
            body: ["iv": iv, "cipher": cipher, "anonId": anonId, "seq": seq, "ts": ts])
    }

    static func history(_ roomId: String, afterSeq: Int = 0, limit: Int = 100) async throws -> HistoryResult {
        try await APIClient.request("/temp/rooms/\(roomId)/messages?afterSeq=\(afterSeq)&limit=\(limit)")
    }
}

// MARK: - 账号聊天

enum ChatAPI {
    struct RoomsResult: Decodable {
        let ok: Bool
        let rooms: [RoomMeta]
    }
    
    struct HistoryResult: Decodable {
        let ok: Bool
        let messages: [ChatMsg]
        let hasMore: Bool
    }
    
    struct CreateResult: Decodable {
        let ok: Bool
        let roomId: String
        let token: String
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
    
    static func rooms(token: String) async throws -> RoomsResult {
        try await APIClient.request("/chat/rooms", token: token)
    }
    
    static func history(_ roomId: String, token: String, afterSeq: Int = 0, limit: Int = 100) async throws -> HistoryResult {
        try await APIClient.request("/chat/rooms/\(roomId)/messages?afterSeq=\(afterSeq)&limit=\(limit)", token: token)
    }
    
    static func createRoom(type: String, memberIds: [Int], nameEnc: String?, wrappedKeys: [WrappedKeyEntry], token: String) async throws -> CreateResult {
        try await APIClient.request("/chat/rooms", method: "POST", body: [
            "type": type,
            "memberIds": memberIds,
            "nameEnc": nameEnc,
            "wrappedKeys": wrappedKeys
        ], token: token)
    }
    
    static func send(_ roomId: String, iv: String, cipher: String, seq: Int, ts: Int64, kind: String, meta: String? = nil, token: String) async throws -> SendResult {
        try await APIClient.request("/chat/rooms/\(roomId)/messages", method: "POST", body: [
            "iv": iv,
            "cipher": cipher,
            "seq": seq,
            "ts": ts,
            "kind": kind,
            "meta": meta
        ], token: token)
    }
    
    static func markRead(_ roomId: String, lastSeq: Int, token: String) async throws -> MarkReadResult {
        try await APIClient.request("/chat/rooms/\(roomId)/read?lastSeq=\(lastSeq)", token: token)
    }
}

// MARK: - 邀请链接

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

    static func create() async throws -> CreateResult {
        try await APIClient.request("/invite/create", method: "POST")
    }
}

// 服务器成功但不返回 body 的响应
struct Empty: Decodable {}
