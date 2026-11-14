import UserNotifications
import Foundation
import UIKit

/// 本地推送通知管理
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() { super.init() }

    var currentBadgeCount = 0

    /// 已授权?(不含"稍后")
    var isAuthorized: Bool {
        // Use synchronous API to avoid async issues in computed property
        var settings: UNNotificationSettings?
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { s in
            settings = s
            semaphore.signal()
        }
        semaphore.wait()
        guard let s = settings else { return false }
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    /// 请求权限(用户会看到系统弹窗)
    func requestAuthorization() async {
        do {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            print("[Notification] authorization granted")
        } catch {
            print("[Notification] authorization failed: \(error)")
        }
    }

    /// 立即发一条通知
    func send(_ title: String, body: String, roomId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let roomId { content.userInfo = ["room_id": roomId] }
        currentBadgeCount += 1
        UIApplication.shared.applicationIconBadgeNumber = currentBadgeCount
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { print("[Notification] send error: \(err)") }
        }
    }

    /// 当新消息到达时调用;App在前台不弹窗只更新角标,后台则弹窗+角标
    func onNewMessage(inRoom roomId: String, senderLabel: String?, text: String) async {
        guard !isAppInForeground() else {
            updateBadgeCountFromAppState()
            return
        }
        let label = UserDefaults.standard.string(forKey: "lmh.room.label.\(roomId)")
            ?? String((roomId as NSString).substring(to: min(roomId.count, 8)))
        let preview = (text.count > 50 ? String(text.prefix(50)) + "…" : text).replacingOccurrences(of: "\n", with: " ")
        let body = "\(senderLabel ?? "成员"): \(preview)"
        send(label, body: body, roomId: roomId)
    }

    /// 清角标(进入聊天时调用)
    func clearBadge() {
        guard currentBadgeCount > 0 else { return }
        currentBadgeCount -= 1
        UIApplication.shared.applicationIconBadgeNumber = currentBadgeCount
    }

    /// 根据 AppState 中的 unread 更新角标
    func syncBadgeFromAppState() {
        let count = max(0, AppState.shared.unreadRoomCount)
        currentBadgeCount = count
        UIApplication.shared.applicationIconBadgeNumber = count
    }

    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    private func isAppInForeground() -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return false }
        return scene.activationState == .foregroundActive
    }

    private func updateBadgeCountFromAppState() {
        let count = max(0, AppState.shared.unreadRoomCount)
        currentBadgeCount = count
        UIApplication.shared.applicationIconBadgeNumber = count
    }
}
