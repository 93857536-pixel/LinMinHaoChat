import CryptoKit
import Foundation

/// 本地"最近聊天"预览缓存(仅用于聊天列表展示,不参与任何加解密/传输)。
/// 服务器 RoomMeta 不含"最后一条消息文本"(E2EE 密文),列表预览需本地缓存最近一条
/// 解密后的消息文本+时间;由聊天室 ViewModel 在收到/发送消息时写入。
/// 隐私安全:明文只存本机 UserDefaults,绝不上传;房间清空后随 markRead/delete 失效。
final class ChatPreviewStore: ObservableObject {
    static let shared = ChatPreviewStore()

    struct Preview: Codable {
        let text: String
        let ts: Int64
        let senderLabel: String?
    }

    private static let key = "lmh.chat.preview.v1"

    private var cache: [String: Preview] = [:]

    private init() { load() }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let c = try? JSONDecoder().decode([String: Preview].self, from: d) else { return }
        cache = c
    }

    private func persist() {
        let d = (try? JSONEncoder().encode(cache))
        if let d { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    @discardableResult
    func set(_ roomId: String, text: String, ts: Int64, senderLabel: String?) -> Preview {
        let p = Preview(text: text, ts: ts, senderLabel: senderLabel)
        cache[roomId] = p
        persist()
        return p
    }

    func preview(_ roomId: String) -> Preview? { cache[roomId] }

    /// 清空某房间预览(删除聊天记录时调用)
    func clear(_ roomId: String) {
        cache.removeValue(forKey: roomId)
        persist()
    }
}
