import Foundation

/// 本地会话开关(免打扰):仅存本机 UserDefaults, 不上传。
/// 通知/角标与聊天列表共用同一数据源, 保证「关免打扰 → 不弹窗、不角标」一致。
final class RoomFlagsStore: ObservableObject {
    static let shared = RoomFlagsStore()

    private static let key = "lmh.room.muted.v1"

    /// 免打扰房间 ID 集合(开启后:不弹系统通知、不计入角标)
    @Published private(set) var mutedRoomIds: Set<String> = []

    private init() {
        if let d = UserDefaults.standard.string(forKey: Self.key),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: Data(d.utf8)) {
            mutedRoomIds = ids
        }
    }

    func isMuted(_ roomId: String) -> Bool { mutedRoomIds.contains(roomId) }

    @discardableResult
    func toggleMuted(_ roomId: String) -> Bool {
        if mutedRoomIds.contains(roomId) { mutedRoomIds.remove(roomId) }
        else { mutedRoomIds.insert(roomId) }
        persist()
        return mutedRoomIds.contains(roomId)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(mutedRoomIds) {
            UserDefaults.standard.set(String(data: d, encoding: .utf8) ?? "", forKey: Self.key)
        }
    }
}
