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
/// 基址自动指向 https://linminhao.top/api,用户无需也不应知道该地址。
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
        guard (200..<300).contains(http.statusCode) else {
            var msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            var json: [String: Any]?
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = obj
                if let e = obj["error"] as? String { msg = e }
            }
            throw ApiError(status: http.statusCode, message: msg, data: json)
        }
        return data
    }
}

// MARK: - 认证

enum AuthAPI {
    struct SendCodeResult: Decodable { let ok: Bool; let expiresInSec: Int }
    struct AuthResult: Decodable {
        let ok: Bool
        let token: String
        let sessionId: String
        struct User: Decodable { let id: Int; let handle: String? }
        let user: User
    }

    static func sendCode(type: String, target: String) async throws -> SendCodeResult {
        try await APIClient.request("/auth/send-code", body: ["type": type, "target": target])
    }

    static func register(type: String, target: String, code: String, handle: String?,
                         deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        var body: [String: Any] = ["type": type, "target": target, "code": code,
                                   "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub]
        if let handle { body["handle"] = handle }
        return try await APIClient.request("/auth/register", body: body)
    }

    static func login(type: String, target: String, code: String,
                      deviceId: String, ed25519Pub: String, ecdhPub: String) async throws -> AuthResult {
        try await APIClient.request("/auth/login",
                                    body: ["type": type, "target": target, "code": code,
                                           "deviceId": deviceId, "ed25519Pub": ed25519Pub, "ecdhPub": ecdhPub])
    }

    static func logout(sessionId: String, token: String) async throws {
        let _: Empty = try await APIClient.request("/auth/logout", body: ["sessionId": sessionId], token: token)
    }
}

// MARK: - 密钥

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

// MARK: - 账号聊天(骨架:类型就位,下一阶段接线)

enum ChatAPI {
    static func rooms(token: String) async throws {
        struct R: Decodable { let ok: Bool; let rooms: [RoomMeta] }
        let _: R = try await APIClient.request("/chat/rooms", token: token)
    }
}

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
