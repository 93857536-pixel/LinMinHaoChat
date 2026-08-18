// CryptoKit ↔ WebCrypto 协议交叉验证 harness(与 ios/LinMinHaoChat/Crypto 共用源码)
// 用法:
//   swiftc -O Base64.swift MessageCrypto.swift SessionKeyUtil.swift verify_crypto.swift -o /tmp/verify_crypto
//   echo '{"mode":"encrypt","roomId":"r","seq":1,"ts":123,"plain":"你好"}' | /tmp/verify_crypto
//   echo '{"mode":"decrypt","roomId":"r","seq":1,"ts":123,"iv":"..","ct":".."}' | /tmp/verify_crypto
import CryptoKit
import Foundation

func readJSON() throws -> [String: Any] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "harness", code: 1)
    }
    return obj
}

func out(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    print(String(data: data, encoding: .utf8)!)
}

do {
    let input = try readJSON()
    guard let mode = input["mode"] as? String else { throw NSError(domain: "harness", code: 2, userInfo: [NSLocalizedDescriptionKey: "no mode"]) }
    let roomId = input["roomId"] as? String ?? ""
    let seq = input["seq"] as? Int ?? 0
    let ts = input["ts"] as? Int64 ?? 0

    switch mode {
    case "encrypt":
        let keyB64 = input["key"] as? String ?? "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" // 32B 固定测试密钥
        guard let keyData = Data(base64Encoded: keyB64), keyData.count == 32,
              let plain = input["plain"] as? String else { throw NSError(domain: "harness", code: 3) }
        let key = SymmetricKey(data: keyData)
        let enc = try MessageCrypto.encryptMessage(sessionKey: key, plaintext: plain, roomId: roomId, seq: seq, ts: ts)
        out(["iv": enc.iv, "ct": enc.ct])

    case "decrypt":
        let keyB64 = input["key"] as? String ?? "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
        guard let keyData = Data(base64Encoded: keyB64), keyData.count == 32,
              let iv = input["iv"] as? String, let ct = input["ct"] as? String else { throw NSError(domain: "harness", code: 3) }
        let key = SymmetricKey(data: keyData)
        let payload = MessageCrypto.EncryptedPayload(iv: iv, ct: ct)
        let plain = try MessageCrypto.decryptMessage(sessionKey: key, payload: payload, roomId: roomId, seq: seq, ts: ts)
        out(["plain": plain])

    case "self":
        // 本地回环:加密→解密一致 + 篡改 AAD 必须失败 + 错误密钥必须失败
        let key = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let plain = "自检消息:端到端加密 ✓ 你好,世界!"
        let enc = try MessageCrypto.encryptMessage(sessionKey: key, plaintext: plain, roomId: roomId, seq: seq, ts: ts)
        let dec = try MessageCrypto.decryptMessage(sessionKey: key, payload: enc, roomId: roomId, seq: seq, ts: ts)
        guard dec == plain else { throw NSError(domain: "harness", code: 4, userInfo: [NSLocalizedDescriptionKey: "roundtrip mismatch"]) }
        // 篡改 ts → 必须解密失败
        var tampered = false
        do { _ = try MessageCrypto.decryptMessage(sessionKey: key, payload: enc, roomId: roomId, seq: seq, ts: ts + 1); tampered = true } catch {}
        guard !tampered else { throw NSError(domain: "harness", code: 5, userInfo: [NSLocalizedDescriptionKey: "tamper accepted"]) }
        // 错误密钥 → 必须解密失败
        var wrongKeyAccepted = false
        do { _ = try MessageCrypto.decryptMessage(sessionKey: wrongKey, payload: enc, roomId: roomId, seq: seq, ts: ts); wrongKeyAccepted = true } catch {}
        guard !wrongKeyAccepted else { throw NSError(domain: "harness", code: 6, userInfo: [NSLocalizedDescriptionKey: "wrong key accepted"]) }
        out(["ok": true, "note": "roundtrip+tamper+wrongkey passed"])

    case "ecdhShared":
        // 输出与 peerPub 的 ECDH 共享密钥(用于跨端比对)
        guard let peerPubB64 = input["peerPub"] as? String else { throw NSError(domain: "harness", code: 10) }
        guard let peerWire = B64.decode(peerPubB64) else { throw NSError(domain: "harness", code: 11) }
        let kp = P256.KeyAgreement.PrivateKey()
        let myKeys = IdentityCrypto.IdentityKeys(
            deviceId: "dev-s", ed25519PrivB64: "", ecdhPrivB64: B64.encode(kp.rawRepresentation),
            ed25519Pub: "", ecdhPub: B64.encode(IdentityCrypto.pubKeyWireBytes(kp)))
        let peerPub = try IdentityCrypto.importPeerEcdhPub(peerWire)
        let secret = try kp.sharedSecretFromKeyAgreement(with: peerPub)
        let shared = Data(secret.withUnsafeBytes { Array($0) })
        out(["ok": true, "myPub": myKeys.ecdhPub, "shared": B64.encode(shared)])

    case "wrapFor":
        // 用输入的 peer 公钥包装固定会话密钥(模拟 iOS 为新设备/成员包装)
        guard let peerPubB64 = input["peerPub"] as? String else { throw NSError(domain: "harness", code: 9) }
        let wrapper = P256.KeyAgreement.PrivateKey()
        let wrapperKeys = IdentityCrypto.IdentityKeys(
            deviceId: "dev-wrap", ed25519PrivB64: "", ecdhPrivB64: B64.encode(wrapper.rawRepresentation),
            ed25519Pub: "", ecdhPub: B64.encode(IdentityCrypto.pubKeyWireBytes(wrapper)))
        let sessionKeyData = Data(base64Encoded: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")!
        let sessionKey = SymmetricKey(data: sessionKeyData)
        let wrapped = try IdentityCrypto.wrapSessionKey(sessionKey: sessionKey,
                                                       peerEcdhPubB64: peerPubB64, myKeys: wrapperKeys)
        out(["ok": true, "wrapped": wrapped, "wrapperPub": wrapperKeys.ecdhPub])

    case "wrap":
        // 本地 ECDH 包装/解包回环(用固定会话密钥,便于与 node 交叉比对)
        let alice = P256.KeyAgreement.PrivateKey()
        let bob = P256.KeyAgreement.PrivateKey()
        let aliceKeys = IdentityCrypto.IdentityKeys(
            deviceId: "dev-a", ed25519PrivB64: "", ecdhPrivB64: B64.encode(alice.rawRepresentation),
            ed25519Pub: "", ecdhPub: B64.encode(IdentityCrypto.pubKeyWireBytes(alice)))
        let bobKeys = IdentityCrypto.IdentityKeys(
            deviceId: "dev-b", ed25519PrivB64: "", ecdhPrivB64: B64.encode(bob.rawRepresentation),
            ed25519Pub: "", ecdhPub: B64.encode(IdentityCrypto.pubKeyWireBytes(bob)))
        let sessionKeyData = Data(base64Encoded: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")!
        let sessionKey = SymmetricKey(data: sessionKeyData)
        let wrappedForBob = try IdentityCrypto.wrapSessionKey(sessionKey: sessionKey,
                                                              peerEcdhPubB64: bobKeys.ecdhPub, myKeys: aliceKeys)
        let unwrapped = try IdentityCrypto.unwrapSessionKey(wrapped: wrappedForBob, myKeys: bobKeys)
        guard SessionKeyUtil.keyData(unwrapped) == SessionKeyUtil.keyData(sessionKey) else {
            throw NSError(domain: "harness", code: 7, userInfo: [NSLocalizedDescriptionKey: "wrap mismatch"])
        }
        out(["ok": true, "wrapped": wrappedForBob, "alicePub": aliceKeys.ecdhPub, "bobPub": bobKeys.ecdhPub])

    default:
        throw NSError(domain: "harness", code: 8, userInfo: [NSLocalizedDescriptionKey: "unknown mode"])
    }
} catch {
    out(["error": error.localizedDescription])
    exit(1)
}
