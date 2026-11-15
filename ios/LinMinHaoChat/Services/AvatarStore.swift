import SwiftUI
import UIKit

/// 用户头像:上传(相册选图 → 压到 512 方图、剔除 EXIF → POST /avatars)+ 拉取缓存。
///
/// 缓存策略:
/// - 正缓存:NSCache 存 UIImage(内存紧张自动释放)
/// - 负缓存:服务端返回 404(没有头像/无权查看)时不反复请求
/// - 换头像后本人这份立即写回缓存(无需等下次网络)
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()

    private let cache = NSCache<NSString, UIImage>()
    private var noAvatar: Set<Int> = []
    private var inflight: [Int: Task<UIImage?, Never>] = [:]

    /// 我的头像版本号(上传成功后更新;界面据此刷新)
    @Published private(set) var myAvatarUpdatedAt: Int64?

    private func key(_ userId: Int) -> NSString { "avatar-\(userId)" as NSString }

    /// 同步读缓存(不触发网络)
    func cached(userId: Int) -> UIImage? { cache.object(forKey: key(userId)) }

    /// 异步取头像。hasAvatar == false 时直接走兜底(不打网络)。
    func image(userId: Int, hasAvatar: Bool? = nil) async -> UIImage? {
        if let img = cache.object(forKey: key(userId)) { return img }
        if hasAvatar == false { return nil }
        guard userId > 0, AppState.shared.authToken != nil else { return nil }
        if let running = inflight[userId] { return await running.value }
        guard let token = AppState.shared.authToken else { return nil }

        let task = Task<UIImage?, Never> {
            do {
                let data = try await AvatarAPI.download(userId: userId, token: token)
                return UIImage(data: data)
            } catch {
                return nil
            }
        }
        inflight[userId] = task
        let img = await task.value
        inflight[userId] = nil
        if let img { cache.setObject(img, forKey: key(userId)) } else { noAvatar.insert(userId) }
        return img
    }

    /// 上传/更换我的头像(自动压方图 + 去 EXIF)。返回服务端头像版本号。
    @discardableResult
    func upload(_ image: UIImage) async throws -> Int64 {
        guard let token = AppState.shared.authToken, let uid = AppState.shared.userId else {
            throw ApiError(status: 401, message: "请先登录")
        }
        guard let jpeg = Self.normalizedJPEG(image) else {
            throw ApiError(status: 400, message: "图片处理失败,请换一张")
        }
        let r = try await AvatarAPI.upload(jpeg: jpeg, token: token)
        let version = r.avatarUpdatedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        // 立即刷新本地缓存与版本号
        if let squared = UIImage(data: jpeg) { cache.setObject(squared, forKey: key(uid)) }
        noAvatar.remove(uid)
        myAvatarUpdatedAt = version
        AppState.shared.applyAvatar(updatedAt: version)
        return version
    }

    /// 删除我的头像
    func removeMyAvatar() async throws {
        guard let token = AppState.shared.authToken, let uid = AppState.shared.userId else { return }
        try await AvatarAPI.delete(token: token)
        cache.removeObject(forKey: key(uid))
        noAvatar.insert(uid)
        myAvatarUpdatedAt = nil
        AppState.shared.applyAvatar(updatedAt: nil)
    }

    /// 让某人的头像缓存失效(换头像后对方刷新时用)
    func invalidate(userId: Int) {
        cache.removeObject(forKey: key(userId))
        noAvatar.remove(userId)
    }

    /// 居中裁方 + 缩放到 maxSide(默认 512),输出 JPEG。
    /// ⚠️ UIGraphicsImageRenderer 重绘天然丢弃原始 EXIF(含 GPS),不把位置信息传上服务器。
    static func normalizedJPEG(_ image: UIImage, maxSide: CGFloat = 512, quality: CGFloat = 0.85) -> Data? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let target = min(maxSide, max(w, h))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
        let squared = renderer.image { _ in
            // cover:等比放大到填满画布,居中裁掉多余部分(draw 会正确处理 imageOrientation)
            let scale = max(target / w, target / h)
            let drawSize = CGSize(width: w * scale, height: h * scale)
            image.draw(in: CGRect(x: (target - drawSize.width) / 2,
                                  y: (target - drawSize.height) / 2,
                                  width: drawSize.width, height: drawSize.height))
        }
        return squared.jpegData(compressionQuality: quality)
    }
}

/// 圆形头像:有自传头像显示图片,否则回退到「渐变 + 首字母」的 ChatAvatar
struct UserAvatar: View {
    let userId: Int
    /// 显示名(昵称 → 账号 ID),用于兜底首字母与无障碍
    let label: String
    /// 服务端告知是否有头像;nil = 未知(仍尝试拉取)
    var hasAvatar: Bool? = nil
    var isGroup = false
    var size: CGFloat = 44

    @State private var image: UIImage?
    /// 观察头像存储:本人换/移除头像后 myAvatarUpdatedAt(版本号)变化 →
    /// task id 变化 → 立即重取(命中缓存,无网络),不必退出重进
    @ObservedObject private var avatarStore = AvatarStore.shared

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(.separator).opacity(0.35), lineWidth: 0.5))
            } else {
                ChatAvatar(label: label, isGroup: isGroup, size: size)
            }
        }
        .accessibilityLabel(label)
        .task(id: "\(userId)|\(hasAvatar.map(String.init) ?? "-")|\(avatarStore.myAvatarUpdatedAt ?? 0)") {
            image = await avatarStore.image(userId: userId, hasAvatar: hasAvatar)
        }
    }
}
