import Foundation

/// 本地常用联系人(仅本机 UserDefaults,不上传;服务器无好友系统)。
/// 每项 = 对方账号用户 ID + 本地显示名。用于"发起聊天"快速入口。
final class CommonContactsStore: ObservableObject {
    static let shared = CommonContactsStore()

    struct Contact: Identifiable, Codable, Hashable {
        var id: Int { userId }
        let userId: Int
        var name: String
    }

    @Published var contacts: [Contact] = []
    private static let key = "lmh.common.contacts.v1"

    private init() { load() }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let c = try? JSONDecoder().decode([Contact].self, from: d) else { return }
        contacts = c
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }

    /// 添加或更新(userId 相同则改名);返回是否已存在
    @discardableResult
    func add(userId: Int, name: String) -> Bool {
        if let idx = contacts.firstIndex(where: { $0.userId == userId }) {
            contacts[idx].name = name.isEmpty ? contacts[idx].name : name
            persist()
            return true
        }
        contacts.append(Contact(userId: userId, name: name.isEmpty ? "账号 \(userId)" : name))
        persist()
        return false
    }

    func remove(_ contact: Contact) {
        contacts.removeAll { $0.userId == contact.userId }
        persist()
    }

    /// 供 SwiftUI .onDelete(IndexSet) 使用(索引基于当前 contacts 顺序)
    func remove(at offsets: IndexSet) {
        contacts.remove(atOffsets: offsets)
        persist()
    }

    /// 新建私聊时把对方加入常用(自动去重)
    func remember(userId: Int, name: String) {
        add(userId: userId, name: name)
    }
}
