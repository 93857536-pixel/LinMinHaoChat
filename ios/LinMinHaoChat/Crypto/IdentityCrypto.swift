import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 身份密钥 + 会话密钥包装 —— 与 web/src/crypto/keys.ts + session.ts 协议对应。
///
/// 每设备一对身份密钥:
/// - Ed25519:签名身份(当前用于设备标识,预留消息签名)
/// - ECDH P-256:密钥交换(包装/解包会话密钥)
///
/// 私钥只存本机 Keychain,绝不上传。服务器只收到 base64 公钥。
///
/// ⚠️ 公钥线格式:web 端用 JWK x||y 拼接成 64 字节(base64)—— 不带 SEC1 的 0x04 前缀;
///    CryptoKit 的 rawRepresentation 是 65 字节(带 0x04)。这里显式做 64↔65 转换,保证字节级兼容。
enum IdentityCrypto {
    struct IdentityKeys: Codable {
        var deviceId: String
        var ed25519PrivB64: String
        var ecdhPrivB64: String
        var ed25519Pub: String   // 32B base64
        var ecdhPub: String      // 64B (x||y) base64
    }

    static let wrapInfo = Data("lmh-session-wrap-v1".utf8)

    // MARK: - 密钥对

    /// 生成本设备身份密钥对
    static func generateIdentity() throws -> IdentityKeys {
        let ed = Curve25519.Signing.PrivateKey()
        let ec = P256.KeyAgreement.PrivateKey()
        let deviceId = String(B64.encodeUrl(Data((0..<9).map { _ in UInt8.random(in: 0...255) }))
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(12))
        return IdentityKeys(
            deviceId: deviceId.isEmpty ? "dev" : deviceId,
            ed25519PrivB64: B64.encode(ed.rawRepresentation),
            ecdhPrivB64: B64.encode(ec.rawRepresentation),
            ed25519Pub: B64.encode(ed.publicKey.rawRepresentation),
            ecdhPub: B64.encode(pubKeyWireBytes(ec))
        )
    }

    /// P-256 私钥 → 公钥线格式(64B x||y;本 SDK 的 rawRepresentation 即此格式,与 web 一致)
    static func pubKeyWireBytes(_ priv: P256.KeyAgreement.PrivateKey) -> Data {
        let raw = priv.publicKey.rawRepresentation
        return raw.count == 65 ? raw.dropFirst() : raw
    }

    /// 导入对端 P-256 公钥 —— 直接接受 64B(x||y)线格式。
    /// ⚠️ Xcode 27 beta 的 CryptoKit 只接受 64B;65B(SEC1 带 0x04)会被拒(incorrectParameterSize)。
    static func importPeerEcdhPub(_ wire: Data) throws -> P256.KeyAgreement.PublicKey {
        try P256.KeyAgreement.PublicKey(rawRepresentation: wire)
    }

    /// 本机 ECDH 私钥(从线格式恢复)
    private static func importMyEcdhPriv(_ b64: String) throws -> P256.KeyAgreement.PrivateKey {
        guard let raw = B64.decode(b64) else { throw CryptoError.missingIdentity }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    // MARK: - 会话密钥包装(账号聊天的 room_keys 机制)

    /// ECDH 共享密钥 → HKDF-SHA256(salt 空, info=lmh-session-wrap-v1) → AES-GCM-256 包装密钥
    private static func deriveWrapKey(_ myPriv: P256.KeyAgreement.PrivateKey, _ peerPub: P256.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let secret = try myPriv.sharedSecretFromKeyAgreement(with: peerPub)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: wrapInfo, outputByteCount: 32)
    }

    /// 用成员公钥包装会话密钥(附带包装者公钥,便于对方解包)—— 与 web wrapSessionKey 同构:
    /// JSON { v:1, iv, ct, pk }
    static func wrapSessionKey(sessionKey: SymmetricKey, peerEcdhPubB64: String, myKeys: IdentityKeys) throws -> String {
        guard let peerWire = B64.decode(peerEcdhPubB64) else { throw CryptoError.badWrap }
        let peerPub = try importPeerEcdhPub(peerWire)
        let myPriv = try importMyEcdhPriv(myKeys.ecdhPrivB64)
        let key = try deriveWrapKey(myPriv, peerPub)
        let iv = MessageCrypto.randomIV()
        let sealed = try AES.GCM.seal(SessionKeyUtil.keyData(sessionKey), using: key, nonce: AES.GCM.Nonce(data: iv))
        let obj: [String: Any] = [
            "v": 1,
            "iv": B64.encode(iv),
            "ct": B64.encode(sealed.ciphertext + sealed.tag),
            "pk": myKeys.ecdhPub,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let s = String(data: data, encoding: .utf8) else { throw CryptoError.badWrap }
        return s
    }

    /// 用我的私钥解开 wrappedKey(wrapped 内含包装者公钥 pk)
    static func unwrapSessionKey(wrapped: String, myKeys: IdentityKeys) throws -> SymmetricKey {
        guard let data = wrapped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["v"] as? Int, v == 1,
              let ivB = obj["iv"] as? String,
              let ctB = obj["ct"] as? String,
              let pkB = obj["pk"] as? String,
              let iv = B64.decode(ivB), iv.count == 12,
              let ct = B64.decode(ctB),
              let peerWire = B64.decode(pkB)
        else { throw CryptoError.badWrap }
        let peerPub = try importPeerEcdhPub(peerWire)
        let myPriv = try importMyEcdhPriv(myKeys.ecdhPrivB64)
        let key = try deriveWrapKey(myPriv, peerPub)
        let box = try AES.GCM.SealedBox(combined: iv + ct)
        let plain = try AES.GCM.open(box, using: key)
        return SymmetricKey(data: plain)
    }

    // MARK: - 口令加密导出包(多设备迁移,与 web exportEncryptedPackage 同构)

    /// PBKDF2-SHA256(CommonCrypto;CryptoKit 无 PBKDF2)
    static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLen: Int) -> Data? {
        var derived = Data(count: keyLen)
        let result: Int32 = derived.withUnsafeMutableBytes { (db: UnsafeMutableRawBufferPointer) in
            salt.withUnsafeBytes { (sb: UnsafeRawBufferPointer) in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password,
                    password.utf8.count,
                    sb.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    db.bindMemory(to: UInt8.self).baseAddress,
                    keyLen
                )
            }
        }
        return result == kCCSuccess ? derived : nil
    }

    /// 导出:PBKDF2(250k) + AES-GCM 加密私钥包 → JSON { v:1, kdf, iter, salt, iv, ct }
    static func exportEncryptedPackage(identity: IdentityKeys, pin: String) throws -> String {
        let salt = MessageCrypto.randomIV() + Data((0..<4).map { _ in UInt8.random(in: 0...255) })  // 16B
        let iv = MessageCrypto.randomIV()
        guard let keyData = pbkdf2SHA256(password: pin, salt: salt, iterations: 250_000, keyLen: 32) else {
            throw CryptoError.badPackage
        }
        let key = SymmetricKey(data: keyData)
        let plain = try JSONEncoder().encode(identity)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: iv))
        let obj: [String: Any] = [
            "v": 1,
            "kdf": "PBKDF2-SHA256",
            "iter": 250_000,
            "salt": B64.encode(salt),
            "iv": B64.encode(iv),
            "ct": B64.encode(sealed.ciphertext + sealed.tag),
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let s = String(data: data, encoding: .utf8) else { throw CryptoError.badPackage }
        return s
    }

    /// 导入:口令解开导出包,覆盖本机身份密钥
    static func importEncryptedPackage(_ pkg: String, pin: String) throws -> IdentityKeys {
        guard let data = pkg.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["v"] as? Int, v == 1,
              let kdf = obj["kdf"] as? String, kdf == "PBKDF2-SHA256",
              let iter = obj["iter"] as? Int,
              let saltB = obj["salt"] as? String,
              let ivB = obj["iv"] as? String,
              let ctB = obj["ct"] as? String,
              let salt = B64.decode(saltB),
              let iv = B64.decode(ivB),
              let ct = B64.decode(ctB)
        else { throw CryptoError.badPackage }
        guard let keyData = pbkdf2SHA256(password: pin, salt: salt, iterations: iter, keyLen: 32) else {
            throw CryptoError.wrongPin
        }
        let key = SymmetricKey(data: keyData)
        do {
            let box = try AES.GCM.SealedBox(combined: iv + ct)
            let plain = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(IdentityKeys.self, from: plain)
        } catch {
            throw CryptoError.wrongPin
        }
    }
}
