import AVFoundation
import AVKit
import CryptoKit
import Photos
import SwiftUI
import UIKit

/// 附件下载+解密的进程内缓存: 同一 attId 只下载/解密一次(会话密钥与 ts 对房间是固定的)。
/// 临时文件落在 tmp/att_<attId>,App 重启由系统清理。
final class AttachmentDecryptCache: @unchecked Sendable {
    static let shared = AttachmentDecryptCache()

    private let lock = NSLock()
    private var fileCache: [String: URL] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]

    /// 取(或下载+解密并落盘)附件明文
    func urlFor(attId: String, download: @escaping () async throws -> Data) async throws -> URL {
        if let u = fileCacheLocked[attId] { return u }
        let d = try await runOnce(attId: attId) { try await download() }
        return materialize(attId: attId, data: d)
    }

    private func runOnce(attId: String, _ make: @escaping () async throws -> Data) async throws -> Data {
        lock.lock()
        if let existing = inFlight[attId] {
            lock.unlock()
            return try await existing.value
        }
        let task = Task<Data, Error> {
            let d = try await make()
            return d
        }
        inFlight[attId] = task
        lock.unlock()
        defer {
            lock.lock()
            inFlight[attId] = nil
            lock.unlock()
        }
        return try await task.value
    }

    private var fileCacheLocked: [String: URL] {
        lock.lock()
        defer { lock.unlock() }
        return fileCache
    }

    private func materialize(attId: String, data: Data) -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let u = fileCache[attId] { return u }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("att_\(attId)")
        do {
            try data.write(to: u, options: .atomic)
            fileCache[attId] = u
        } catch {
            print("[AttachmentDecryptCache] write failed: \(error)")
        }
        return u
    }
}

/// 下载密文 + E2EE 解密,返回本地临时文件 URL(进程内去重,同 attId 只下载一次)
func attachmentDownloadAndDecrypt(attId: String, token: String,
                                  sessionKey: SymmetricKey, roomId: String, ts: Int64) async throws -> URL {
    try await AttachmentDecryptCache.shared.urlFor(attId: attId) {
        let cipher = try await AttachmentAPI.download(attId: attId, token: token)
        let plain = try MessageCrypto.decryptAttachment(sessionKey: sessionKey, data: cipher, roomId: roomId, ts: ts)
        return plain
    }
}

/// 附件解密渲染上下文(账号聊天; 临时/邀请聊天无 ECDH 会话密钥, 附件仍按旧文本气泡显示)
struct AttachmentContext {
    let roomId: String
    let sessionKey: SymmetricKey
    let token: String
}

/// 附件消息的媒体渲染: 图片缩略图 / 视频卡片(点击全屏播放) / 文件卡片(点击分享)。
/// 按需下载密文 → E2EE 解密 → 本地临时文件 → 渲染。
struct AttachmentMediaView: View {
    let msg: DecryptedMsg
    let roomId: String
    let sessionKey: SymmetricKey
    let token: String
    /// 文件附件点击 → 交给外层弹出分享面板
    var onShareFile: ((URL) -> Void)? = nil

    @State private var img: UIImage?
    @State private var videoPlayer: AVPlayer?
    @State private var videoResolved = false
    @State private var loadFailed = false
    @State private var showVideoPlayer = false

    private var att: DecryptedMsg.AttachmentInfo? { msg.att }

    var body: some View {
        if let att {
            content(for: att)
        }
    }

    @ViewBuilder
    private func content(for att: DecryptedMsg.AttachmentInfo) -> some View {
        if att.mime.hasPrefix("image/") {
            imageBubble(att: att)
        } else if att.mime.hasPrefix("video/") {
            videoBubble(att: att)
        } else if att.mime.hasPrefix("audio/") && att.duration != nil {
            EmptyView()   // 语音保持现有交互(点按播放), 由 MessageBubbleView 处理
        } else {
            fileBubble(att: att)
        }
    }

    // MARK: 图片

    private func imageBubble(att: DecryptedMsg.AttachmentInfo) -> some View {
        Group {
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if loadFailed {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("图片加载失败").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 120, height: 80)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("加载中…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 120, height: 80)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear { loadIfNeeded(att: att) }
    }

    // MARK: 视频

    private func videoBubble(att: DecryptedMsg.AttachmentInfo) -> some View {
        Button {
            showVideoPlayer = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                    .frame(width: 200, height: 130)
                VStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                    Text(att.name.isEmpty ? "视频" : att.name)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Text(sizeLabel(att.size))
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showVideoPlayer) {
            VideoPlayerSheet(player: videoPlayer, onNeedPlayer: {
                Task { await resolveVideoPlayer(att: att) }
            })
        }
        .onAppear { loadIfNeeded(att: att) }
    }

    /// 视频全屏播放弹层(未解密完时先显示占位并后台解密)
    private struct VideoPlayerSheet: View {
        let player: AVPlayer?
        let onNeedPlayer: () -> Void
        @State private var busy = true

        var body: some View {
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在解密视频…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { onNeedPlayer() }
            }
        }
    }

    // MARK: 文件卡片

    private func fileBubble(att: DecryptedMsg.AttachmentInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon(att.mime))
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(att.name.isEmpty ? "文件" : att.name)
                    .font(.callout).lineLimit(1)
                Text(sizeLabel(att.size)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minWidth: 160, maxWidth: 240)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture { Task { await shareFile(att: att) } }
        .onAppear { loadIfNeeded(att: att) }
    }

    // MARK: 加载/解密

    private func loadIfNeeded(att: DecryptedMsg.AttachmentInfo) {
        guard !att.attId.isEmpty, img == nil, !loadFailed else { return }
        Task { @MainActor in
            do {
                let url = try await attachmentDownloadAndDecrypt(
                    attId: att.attId, token: token, sessionKey: sessionKey,
                    roomId: roomId, ts: msg.ts
                )
                if att.mime.hasPrefix("image/") {
                    guard let d = try? Data(contentsOf: url), let i = UIImage(data: d) else {
                        loadFailed = true; return
                    }
                    img = i
                } else if att.mime.hasPrefix("video/") {
                    videoPlayer = AVPlayer(url: url)
                    videoResolved = true
                }
            } catch {
                loadFailed = true
            }
        }
    }

    private func resolveVideoPlayer(att: DecryptedMsg.AttachmentInfo) async {
        guard videoPlayer == nil else { return }
        do {
            let url = try await attachmentDownloadAndDecrypt(
                attId: att.attId, token: token, sessionKey: sessionKey,
                roomId: roomId, ts: msg.ts
            )
            videoPlayer = AVPlayer(url: url)
        } catch {
            loadFailed = true
        }
    }

    /// 点击文件卡片 → 解密到临时文件 → 交外层弹分享面板
    private func shareFile(att: DecryptedMsg.AttachmentInfo) async {
        do {
            let url = try await attachmentDownloadAndDecrypt(
                attId: att.attId, token: token, sessionKey: sessionKey,
                roomId: roomId, ts: msg.ts
            )
            onShareFile?(url)
        } catch {
            print("[AttachmentShare] \(error)")
        }
    }

    private func fileIcon(_ mime: String) -> String {
        switch mime {
        case "application/pdf": return "doc.richtext"
        case "application/zip", "application/x-7z-compressed": return "archivebox"
        case "application/json": return "curlybraces"
        case "text/plain", "text/markdown": return "doc.text"
        default: return "doc"
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - 图片保存到相册(需要 NSPhotoLibraryAddUsageDescription 授权)
enum AttachmentSaver {
    static func saveImage(_ image: UIImage) -> Bool {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        return true
    }

    static func ensurePhotoAddPermission() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
}
