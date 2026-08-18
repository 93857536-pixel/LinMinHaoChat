import Foundation

/// 身份密钥持久化(Keychain)。首次启动生成,之后复用 —— 对应 web 的 IndexedDB(lmh-keys)。
enum IdentityStore {
    private static let account = "lmh.identity"

    static func load() -> IdentityCrypto.IdentityKeys? {
        guard let data = KeychainStore.load(account: account) else { return nil }
        return try? JSONDecoder().decode(IdentityCrypto.IdentityKeys.self, from: data)
    }

    /// 幂等:已有则复用,没有则生成并保存
    static func ensure() throws -> IdentityCrypto.IdentityKeys {
        if let existing = load() { return existing }
        let fresh = try IdentityCrypto.generateIdentity()
        try save(fresh)
        return fresh
    }

    static func save(_ identity: IdentityCrypto.IdentityKeys) throws {
        let data = try JSONEncoder().encode(identity)
        try KeychainStore.save(data, account: account)
    }

    static func wipe() {
        KeychainStore.delete(account: account)
    }
}
