import CryptoKit
import Foundation
import Security

/// 密码学错误
enum CryptoError: Error, LocalizedError {
    case badPayload
    case badWrap
    case badPackage
    case wrongPin
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case .badPayload: return "密文载荷格式错误"
        case .badWrap: return "会话密钥包装格式错误"
        case .badPackage: return "导出包格式错误"
        case .wrongPin: return "口令错误或包已损坏"
        case .missingIdentity: return "本机身份密钥缺失"
        }
    }
}

/// 消息加密 —— 与 web/src/crypto/message.ts 完全一致的协议:
///
/// - HKDF-SHA256:IKM=sessionKey, salt=iv(12B), info=`lmh-msg-v1:<roomId>:<seq>` → AES-256-GCM 消息密钥
/// - 每条消息独立随机 IV(12B)
/// - AAD = `<roomId>:<seq>:<ts>`(UTF-8)—— 服务器篡改任一字段都会导致 GCM 认证失败
/// - 载荷:iv(明文 base64) + ct(ciphertext||tag base64)
enum MessageCrypto {
    struct EncryptedPayload {
        let iv: String
        let ct: String
    }

    /// 派生消息密钥(每次消息独立,防 nonce 复用)
    private static func deriveMessageKey(sessionKey: SymmetricKey, iv: Data, roomId: String, seq: Int) -> SymmetricKey {
        let info = Data("lmh-msg-v1:\(roomId):\(seq)".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: iv, info: info, outputByteCount: 32)
    }

    static func randomIV() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// 加密一条消息。
    static func encryptMessage(sessionKey: SymmetricKey, plaintext: String, roomId: String, seq: Int, ts: Int64) throws -> EncryptedPayload {
        let iv = randomIV()
        let key = deriveMessageKey(sessionKey: sessionKey, iv: iv, roomId: roomId, seq: seq)
        let aad = Data("\(roomId):\(seq):\(ts)".utf8)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: AES.GCM.Nonce(data: iv), authenticating: aad)
        let ct = sealed.ciphertext + sealed.tag
        return EncryptedPayload(iv: B64.encode(iv), ct: B64.encode(ct))
    }

    /// 解密一条消息。认证失败/密钥错误/密文被篡改都会抛错。
    static func decryptMessage(sessionKey: SymmetricKey, payload: EncryptedPayload, roomId: String, seq: Int, ts: Int64) throws -> String {
        guard let iv = B64.decode(payload.iv), iv.count == 12,
              let ct = B64.decode(payload.ct), !ct.isEmpty else { throw CryptoError.badPayload }
        let key = deriveMessageKey(sessionKey: sessionKey, iv: iv, roomId: roomId, seq: seq)
        let aad = Data("\(roomId):\(seq):\(ts)".utf8)
        let box = try AES.GCM.SealedBox(combined: iv + ct)
        let plain = try AES.GCM.open(box, using: key, authenticating: aad)
        guard let text = String(data: plain, encoding: .utf8) else { throw CryptoError.badPayload }
        return text
    }

    /// 应用层消息格式:文本 {"t": "..."} / 附件 {"f": {...}}(与 web encodeMessageBody 一致)
    static func encodeMessageBody(text: String) -> String {
        // 手拼 JSON 避免转义差异(web 用 JSON.stringify)
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "{\"t\":\"\(escaped)\"}"
    }

    struct DecodedBody {
        var text: String?
        var attachment: AttachmentMeta?
    }

    struct AttachmentMeta: Codable {
        var attId: String?
        var name: String
        var size: Int
        var mime: String
    }

    static func decodeMessageBody(raw: String) -> DecodedBody {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DecodedBody(text: raw, attachment: nil)
        }
        if let t = obj["t"] as? String { return DecodedBody(text: t, attachment: nil) }
        if let f = obj["f"] {
            if let att = try? JSONDecoder().decode(AttachmentMeta.self, from: JSONSerialization.data(withJSONObject: f)) {
                return DecodedBody(text: nil, attachment: att)
            }
        }
        return DecodedBody(text: nil, attachment: nil)
    }

    /// 附件加密(自描述格式 iv||ct||tag;info=`lmh-att-v1:<roomId>:<ts>`,AAD=`<roomId>:<ts>`)。
    /// ⚠️ 与 web 端差异:web 上传的是裸 ct||tag(iv 丢失,解密端切片逻辑不匹配,疑似 web 潜在 bug,
    ///    见 2026-08-18 iOS 骨架注记);iOS 采用 iv 前置的自描述格式,后续统一协议时回改 web。
    static func encryptAttachment(sessionKey: SymmetricKey, data: Data, roomId: String, ts: Int64) throws -> Data {
        let iv = randomIV()
        let info = Data("lmh-att-v1:\(roomId):\(ts)".utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: iv, info: info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: iv), authenticating: Data("\(roomId):\(ts)".utf8))
        return iv + sealed.ciphertext + sealed.tag
    }

    static func decryptAttachment(sessionKey: SymmetricKey, data: Data, roomId: String, ts: Int64) throws -> Data {
        guard data.count > 12 else { throw CryptoError.badPayload }
        let iv = data.prefix(12)
        let body = data.dropFirst(12)
        let info = Data("lmh-att-v1:\(roomId):\(ts)".utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: iv, info: info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(combined: Data(iv) + body)
        return try AES.GCM.open(box, using: key, authenticating: Data("\(roomId):\(ts)".utf8))
    }
}
