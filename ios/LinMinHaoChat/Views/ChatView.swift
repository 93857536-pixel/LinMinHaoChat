import SwiftUI
import UIKit
import CryptoKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 录音控制器（actor，避免AVAudioRecorder delegate与View交互）
actor VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let engine = AVAudioEngine()
    
    func startRecording(url: URL) throws {
        try engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: engine.inputNode.outputFormat(forBus: 0)) { _, _ in }
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: Int(AVAudioQuality.high.rawValue)
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        recorder?.record()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
    }
    
    func stopRecording() async -> URL? {
        guard let r = recorder else { return nil }
        timer?.invalidate(); timer = nil
        r.stop()
        do { try engine.inputNode.removeTap(onBus: 0) } catch {}
        engine.reset()
        do { try AVAudioSession.sharedInstance().setActive(false) } catch {}
        let u = r.url
        recorder = nil
        return u
    }
    
    var isRecording: Bool { recorder?.isRecording ?? false }
    var currentDuration: Double { _lastDuration }
    private var _lastDuration: Double = 0
    
    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        _lastDuration = r.currentTime
    }
}

enum VoiceError: LocalizedError {
    case permissionDenied, engineAlreadyRunning, recordFailed(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要麦克风权限"
        case .engineAlreadyRunning: return "音频引擎正在使用"
        case .recordFailed(let m): return "录音失败: \(m)"
        }
    }
}

struct ChatView: View {
    let session: ChatRoomSession
    
    @StateObject private var viewModel: ChatRoomViewModel
    @State private var inputText = ""
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool
    @State private var copiedMsgId: String?
    @State private var selectedImage: UIImage?
    @State private var isSending = false
    @State private var showPicker = false
    @State private var showForwardSheet = false
    @State private var forwardMsg: DecryptedMsg?
    @State private var rooms: [(id: String, name: String)] = []
    @State private var isForwarding = false
    @State private var starredMsgIds = Set<String>()
    @State private var showStarredSheet = false
    @State private var showMemberManage = false
    @State private var roomType: String?
    @State private var roomLabel = ""
    // 录音状态
    @State private var isRecording = false
    @State private var recordDuration: Double = 0
    @State private var recordingURL: URL?
    // 附件选择(视频/文件)
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var selectedFileURL: URL?
    @State private var showVideoPicker = false
    @State private var showFilePicker = false
    @State private var fileSending = false
    /// 引用回复目标消息（nil = 无引用）
    @State private var quoteMsg: DecryptedMsg?
    /// 本地消息搜索
    @State private var showSearch = false
    @State private var searchQuery = ""
    
    private let recorder = VoiceRecorder()
    private let audioPlayer = AVAudioPlayerCache()

    init(session: ChatRoomSession) {
        self.session = session
        _viewModel = StateObject(wrappedValue: ChatRoomViewModel(roomId: session.roomId, token: session.token, identity: session.identity))
    }
    
    
    var body: some View {
        VStack(spacing: 0) {
            // 状态栏
            HStack(spacing: 6) {
                Circle().fill(viewModel.isReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(viewModel.statusText).font(.caption)
                Spacer()
                if viewModel.peerTyping {
                    HStack(spacing: 3) {
                        Text("对方正在输入").font(.caption).foregroundStyle(Color.accentColor)
                        ProgressView().controlSize(.mini)
                    }
                } else if let n = viewModel.onlineCount, n > 0 {
                    Text("\(n) 人在线").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
            Divider()
            
            // 录音指示器
            if isRecording {
                HStack {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("录音中 \(Int(recordDuration))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
            }
            
            // 消息列表
            if viewModel.messages.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                    Text("端到端加密会话已建立").font(.headline)
                    Text("只有成员能读取消息内容").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        messageListView
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        if let last = viewModel.messages.last {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: searchQuery) { _, q in
                        // 输入时保持滚动位置，不自动滚到底部
                    }
                }
            }

            Divider()

            // 引用卡片（显示在输入框上方）
            quoteCard

            // 搜索条
            if showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索消息…", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Button("清除") { searchQuery = ""; showSearch = false }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }

            // 附件预览(视频/文件待发)
            if let url = selectedFileURL {
                filePreviewRow(url: url)
            } else if selectedVideoItem != nil {
                HStack {
                    ProgressView()
                    Text("正在准备视频…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .onChange(of: selectedVideoItem) { _, item in
                    Task { await pickVideo(item) }
                }
            }
            
            // 图片预览
            if let img = selectedImage {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill).frame(height: 180).clipped()
                    .overlay(alignment: .topTrailing) {
                        Button { selectedImage = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white)
                                .background(Color.black.opacity(0.5), in: Circle())
                        }.padding()
                    }.padding(.horizontal)
            }
            
            // 输入栏
            HStack(alignment: .bottom, spacing: 10) {
            // 「+」菜单: 拍照 / 视频 / 文件
            Menu("附件") {
                Button { showPicker = true } label: { Label("拍照 / 相册", systemImage: "camera") }
                Button {
                    showFilePicker = true
                } label: { Label("视频", systemImage: "video") }
                Button {
                    showFilePicker = true
                } label: { Label("文件", systemImage: "doc") }
            }
                
                // 文本输入(输入时发 typing 帧,对方显示"正在输入")
                TextField("加密消息", text: $inputText, axis: .vertical).lineLimit(1...5).focused($inputFocused).lmhChatInputBubble()
                    .onChange(of: inputText) { _ in viewModel.notifyTyping() }
                
                // 发送/录音按钮
                if isRecording {
                    Button { cancelRecording() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 24)).frame(width: 38, height: 38)
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        if let img = selectedImage {
                            selectedImage = nil
                            Task { await sendAttachment(img) }
                            return
                        }
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let text = inputText; inputText = ""
                            let qid = quoteMsg?.id
                            if let qm = quoteMsg { viewModel.markQuoteRef(qm, qm.text) }
                            Task { await viewModel.send(text, quoteMsgId: qid) }
                            quoteMsg = nil
                        } else {
                            startRecording()
                        }
                    } label: {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Image(systemName: "paperplane.fill").font(.system(size: 18))
                                .frame(width: 38, height: 38)
                                .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                        } else {
                            Image(systemName: "mic.fill").font(.system(size: 18))
                                .frame(width: 38, height: 38)
                                .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                        }
                    }
                    .disabled(isSending && selectedImage != nil)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle("加密聊天").navigationBarTitleDisplayMode(.inline)
        .toolbar { 
            if roomType == "group" {
                ToolbarItem(placement: .principal) { Text(roomLabel).font(.headline).lineLimit(1) }
                ToolbarItem(placement: .primaryAction) { Button { showMemberManage = true } label: { Image(systemName: "person.2") } }
                ToolbarItem(placement: .primaryAction) { Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass").foregroundColor(showSearch ? Color.accentColor : Color.secondary) } }
            } else {
                ToolbarItem(placement: .primaryAction) { Button { showSearch.toggle()} label: { Image(systemName: "magnifyingglass").foregroundColor(showSearch ? Color.accentColor : Color.secondary) } }
            }
        }
        .sheet(isPresented: $showMemberManage) {
            MemberManageView(roomId: session.roomId, sessionToken: session.token, sessionKeyProvider: { viewModel.currentSessionKey })
                .environmentObject(AppState.shared)
        }
        .task {
            await viewModel.start()
            // 拉房间信息获取类型与本地标签
            do {
                let info = try await ChatAPI.room(session.roomId, token: session.token)
                roomType = info.room.type
                // 刷新本地标签缓存
                if let localLabel = UserDefaults.standard.string(forKey: "lmh.room.label.\(session.roomId)") {
                    roomLabel = localLabel
                } else if roomType == "dm" {
                    roomLabel = "私聊"
                } else {
                    roomLabel = "群聊"
                }
                // 清除本房间通知角标
                NotificationManager.shared.clearBadge()
            } catch { /* 静默 */ }
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: viewModel.errorMessage) { _, msg in
            if let msg = msg, !msg.isEmpty { errorMessage = msg; viewModel.errorMessage = nil }
        }
        .toast(message: "已复制", show: copiedMsgId != nil)
        .onChange(of: copiedMsgId) { _, id in
            if id != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedMsgId = nil } }
        }
        .sheet(isPresented: $showPicker) { ImagePicker(image: $selectedImage) }
        .sheet(isPresented: $showForwardSheet) { forwardSheet }
        .sheet(isPresented: $showStarredSheet) { starredSheet }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let u = urls.first { selectedFileURL = u }
            case .failure: break
            }
        }
        .onAppear { loadStarred() }
        .task { await setupAudioSession() }
    }
    
    // MARK: - 录音控制
    private func setupAudioSession() async {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            let status = AVAudioSession.sharedInstance().recordPermission
            if status != .granted { errorMessage = "需要麦克风权限以发送语音消息" }
        } catch {
            errorMessage = "音频设置失败: \(error.localizedDescription)"
        }
    }
    
    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        recordingURL = url
        Task {
            do {
                try await recorder.startRecording(url: url)
                isRecording = true
            } catch {
                errorMessage = (error as? VoiceError)?.errorDescription ?? "录音失败"
            }
        }
    }
    
    private func stopRecording() async {
        isRecording = false
        guard let url = await recorder.stopRecording() else { return }
        recordDuration = 0
        let dur = Int(recordDuration)
        await sendVoice(url: url, duration: dur)
    }
    
    private func cancelRecording() {
        Task { await stopRecording() }
    }

    // MARK: - 视频(从相册选择)

    private func pickVideo(_ item: PhotosPickerItem?) async {
        guard let item else { selectedVideoItem = nil; return }
        do {
            if let url = try await item.loadTransferable(type: URL.self) {
                selectedFileURL = url
                selectedVideoItem = nil
            }
        } catch {
            errorMessage = "无法读取所选视频"
        }
    }

    // MARK: - 文件上传(发送任意附件)

    /// 加密并上传文件,序列化为 attMeta(与语音+图片同构),发送消息帧
    /// 加密并上传文件,序列化为 attMeta(与语音+图片同构),发送消息帧
    private func sendFileAt(url: URL) async {
        guard let token = AppState.shared.authToken,
              let sessionKey = viewModel.currentSessionKey else {
            errorMessage = "未登录或密钥缺失"; return
        }
        isSending = true
        defer { isSending = false; selectedFileURL = nil; fileSending = false }
        do {
            let data = try Data(contentsOf: url)
            let name = (url.lastPathComponent as NSString).deletingPathExtension
            let ext = url.pathExtension.lowercased()
            let filename = name + (ext.isEmpty ? "" : ".\(ext)")
            let mime = mimeTypeFromExt(ext)
            let ts = TimeUtil.nowMs
            let encData = try MessageCrypto.encryptAttachment(sessionKey: sessionKey, data: data, roomId: session.roomId, ts: ts)
            let upload = try await AttachmentAPI.upload(roomId: session.roomId, mimeType: mime, data: encData, token: token)
            let attMeta = "{\"f\":{\"attId\":\"\(upload.attId)\",\"name\":\"\(filename)\",\"size\":\(data.count),\"mime\":\"\(mime)\"}}"
            let plainMeta = "{\"attId\":\"\(upload.attId)\",\"mime\":\"\(mime)\",\"size\":\(data.count)}"
            let targetSeq = viewModel.nextSeq
            let encMsg = try MessageCrypto.encryptMessage(sessionKey: sessionKey, plaintext: attMeta, roomId: session.roomId, seq: targetSeq, ts: ts)
            let r = try await ChatAPI.send(session.roomId, iv: encMsg.iv, cipher: encMsg.ct, seq: targetSeq, ts: ts, kind: "attachment", meta: plainMeta, token: token)
            let attInfo = DecryptedMsg.AttachmentInfo(attId: upload.attId, name: filename, size: data.count, mime: mime)
            viewModel.messages.append(DecryptedMsg(id: r.id, seq: r.seq, label: "我", mine: true, text: filename, ts: r.ts, kind: "attachment", att: attInfo, isRead: true))
            viewModel.updatePreview()
        } catch {
            errorMessage = "文件发送失败: \(error.localizedDescription)"
        }
    }


    private func mimeTypeFromExt(_ ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mp4": return "video/mp4"
        case "m4a", "m4v": return "audio/mp4"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "7z": return "application/x-7z-compressed"
        case "json": return "application/json"
        case "txt", "text": return "text/plain"
        case "md": return "text/markdown"
        default: return "application/octet-stream"
        }
    }

    /// 当前已选文件的预览行(显示文件名+大小,支持取消/重新选)
    private func filePreviewRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill").font(.title3).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text((url.lastPathComponent as NSString).deletingPathExtension)
                    .font(.caption).lineLimit(1)
                Text(mimeTypeFromExt(url.pathExtension.lowercased()))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { selectedFileURL = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
    
    private func sendVoice(url: URL, duration: Int) async {
        guard let token = AppState.shared.authToken,
              let sessionKey = viewModel.currentSessionKey else {
            errorMessage = "未登录或密钥缺失"; return
        }
        isSending = true
        defer { isSending = false }
        do {
            let data = try Data(contentsOf: url)
            let ts = TimeUtil.nowMs
            let encData = try MessageCrypto.encryptAttachment(sessionKey: sessionKey, data: data, roomId: session.roomId, ts: ts)
            let upload = try await AttachmentAPI.upload(roomId: session.roomId, mimeType: "audio/aac", data: encData, token: token)
            let attMeta = "{\"f\":{\"attId\":\"\(upload.attId)\",\"name\":\"voice.m4a\",\"size\":\(data.count),\"mime\":\"audio/aac\",\"duration\":\(duration)}}"
            let plainMeta = "{\"attId\":\"\(upload.attId)\",\"mime\":\"audio/aac\",\"size\":\(data.count),\"duration\":\(duration)}"
            let targetSeq = viewModel.nextSeq
            let encMsg = try MessageCrypto.encryptMessage(sessionKey: sessionKey, plaintext: attMeta, roomId: session.roomId, seq: targetSeq, ts: ts)
            let r = try await ChatAPI.send(session.roomId, iv: encMsg.iv, cipher: encMsg.ct, seq: targetSeq, ts: ts, kind: "attachment", meta: plainMeta, token: token)
            let attInfo = DecryptedMsg.AttachmentInfo(attId: upload.attId, name: "voice.m4a", size: data.count, mime: "audio/aac", duration: duration)
            viewModel.messages.append(DecryptedMsg(id: r.id, seq: r.seq, label: "我", mine: true, text: "🎙️ 语音 (\(Int(recordDuration))s)", ts: r.ts, kind: "attachment", att: attInfo, isRead: true))
            viewModel.nextSeq = r.seq
            viewModel.updatePreview()
        } catch {
            errorMessage = "语音发送失败: \(error.localizedDescription)"
        }
    }
    
    private func makeVoicePlayAction(_ msg: DecryptedMsg) -> () -> Void {
        return { [weak viewModel] in
            Task {
                guard let vm = viewModel,
                      let token = AppState.shared.authToken else { return }
                let attId = msg.att?.attId ?? ""
                guard !attId.isEmpty else { return }
                do {
                    let data = try await AttachmentAPI.download(attId: attId, token: token)
                    let sessionKey = vm.currentSessionKey
                    guard let sessionKey else { return }
                    let decrypted = try MessageCrypto.decryptAttachment(sessionKey: sessionKey, data: data, roomId: vm.roomId, ts: msg.ts)
                    let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(msg.id).m4a")
                    try decrypted.write(to: tempUrl)
                    await vm.audioPlayer.play(tempUrl, duration: msg.att?.duration ?? 0)
                } catch {
                    print("[VoicePlay] Error: \(error)")
                }
            }
        }
    }
    
    // MARK: - 消息列表视图(拆成独立计算属性避免 SwiftUI 类型推断超时)
    @ViewBuilder
    private var messageListView: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [DecryptedMsg] = query.isEmpty
            ? viewModel.messages
            : viewModel.messages.filter { $0.text.localizedCaseInsensitiveContains(query) }
        ForEach(filtered) { msg in
            MessageBubbleView(
                msg: msg,
                onCopy: { copyToClipboard(msg.text) },
                onDelete: viewModel.messages.contains(where: { $0.id == msg.id }) ? { viewModel.deleteMessage(msg.id) } : nil,
                onForward: { forwardMsg = msg; showForwardSheet = true },
                isStarred: starredMsgIds.contains(msg.id),
                onStar: { Task { await toggleStar(msg) } },
                onPlayVoice: makeVoicePlayAction(msg),
                attachmentContext: makeAttachmentContext(msg),
                onSaveImage: makeSaveImageAction(msg),
                onShareFile: { url in Task { await shareDecrypted(url: url) } },
                onQuote: { quoteMsg = $0 }
            )
            .id(msg.id)
        }
        if !query.isEmpty && filtered.isEmpty {
            Text("未找到匹配「\(query)」的消息")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    // MARK: - 附件媒体(图片缩略图/视频播放/文件分享)
    private func makeAttachmentContext(_ msg: DecryptedMsg) -> AttachmentContext? {
        guard msg.kind == "attachment",
              let key = viewModel.currentSessionKey,
              let token = AppState.shared.authToken else { return nil }
        return AttachmentContext(roomId: session.roomId, sessionKey: key, token: token)
    }

    /// 引用卡片（显示在输入框上方，点击可取消）
    private var quoteCard: some View {
        Group {
            if let qm = quoteMsg {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.accentColor).frame(width: 3).cornerRadius(2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(qm.label).font(.caption2).foregroundStyle(.secondary)
                        Text(qm.text.count > 30 ? String(qm.text.prefix(30)) + "…" : qm.text)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    Spacer(minLength: 8)
                    Button { quoteMsg = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// 图片附件「保存到相册」: 解密到本地临时文件 → 写系统相册(需相册写入授权)
    private func makeSaveImageAction(_ msg: DecryptedMsg) -> (() -> Void)? {
        guard msg.kind == "attachment",
              msg.att?.mime.hasPrefix("image/") == true else { return nil }
        return { [weak viewModel] in
            Task {
                guard let vm = viewModel,
                      let token = AppState.shared.authToken,
                      let key = vm.currentSessionKey else { return }
                do {
                    let url = try await attachmentDownloadAndDecrypt(
                        attId: msg.att!.attId, token: token, sessionKey: key,
                        roomId: self.session.roomId, ts: msg.ts)
                    guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return }
                    let ok = await AttachmentSaver.ensurePhotoAddPermission()
                    if ok { AttachmentSaver.saveImage(img) }
                } catch {
                    print("[SaveImage] \(error)")
                }
            }
        }
    }

    /// 解密后的文件 → 系统分享面板
    @MainActor
    private func shareDecrypted(url: URL) {
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rc = scene.keyWindow?.rootViewController else { return }
        rc.present(ac, animated: true)
    }

    // MARK: - 收藏
    private func toggleStar(_ msg: DecryptedMsg) async {
        guard let token = AppState.shared.authToken else { return }
        if starredMsgIds.contains(msg.id) {
            do {
                try await StarredAPI.unstar(msg.id, token: token)
                starredMsgIds.remove(msg.id)
            } catch {
                errorMessage = "取消收藏失败"
            }
        } else {
            do {
                try await StarredAPI.star(msg.id, token: token)
                starredMsgIds.insert(msg.id)
            } catch {
                errorMessage = "收藏失败"
            }
        }
    }
    
    private func loadStarred() {
        guard let token = AppState.shared.authToken else { return }
        Task {
            do {
                let starred = try await StarredAPI.list(token: token)
                starredMsgIds = Set(starred.map { $0.id })
            } catch {}
        }
    }
    
    private var starredSheet: some View {
        NavigationView {
            List {
                if starredMsgIds.isEmpty {
                    Text("暂无收藏消息")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .navigationTitle("收藏消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showStarredSheet = false }
                }
            }
        }
    }
    
    // MARK: - 转发
    private var forwardSheet: some View {
        NavigationView {
            List(rooms, id: \.id) { room in
                Button {
                    Task { await forwardToRoom(room.id) }
                } label: {
                    HStack {
                        Text(room.name).font(.body)
                        Spacer()
                    }
                }
            }
            .navigationTitle("转发到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showForwardSheet = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isForwarding { ProgressView() }
                }
            }
            .task { await loadRooms() }
        }
    }
    
    private func loadRooms() async {
        guard let token = AppState.shared.authToken else { return }
        do {
            let result = try await ChatAPI.rooms(token: token)
            rooms = result.rooms.map { ($0.id, $0.nameEnc ?? "未命名") }
        } catch {
            errorMessage = "加载房间列表失败"
        }
    }
    
    private func forwardToRoom(_ targetRoomId: String) async {
        guard let msg = forwardMsg,
              let token = AppState.shared.authToken,
              let sessionKey = viewModel.currentSessionKey else {
            errorMessage = "转发失败"
            return
        }
        isForwarding = true
        defer { isForwarding = false }
        
        do {
            let ts = TimeUtil.nowMs
            let targetSeq = viewModel.nextSeq
            let forwardedText = "↪ 转发: \(msg.text)"
            let enc = try MessageCrypto.encryptMessage(sessionKey: sessionKey,
                                                       plaintext: MessageCrypto.encodeMessageBody(text: forwardedText),
                                                       roomId: targetRoomId, seq: targetSeq, ts: ts)
            let r = try await ChatAPI.send(targetRoomId, iv: enc.iv, cipher: enc.ct,
                                           seq: targetSeq, ts: ts, kind: "msg", token: token)
            
            viewModel.messages.append(DecryptedMsg(id: r.id, seq: r.seq, label: "我", mine: true,
                                                   text: forwardedText, ts: r.ts, kind: "msg"))
            
            showForwardSheet = false
            forwardMsg = nil
        } catch {
            errorMessage = "转发失败: \(error.localizedDescription)"
        }
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text; copiedMsgId = "copied"
    }
    
    // MARK: - 图片发送
    private func sendAttachment(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.8),
              let token = AppState.shared.authToken,
              let sessionKey = viewModel.currentSessionKey else {
            errorMessage = "图片处理失败"; return
        }
        isSending = true; defer { isSending = false }
        do {
            let ts = TimeUtil.nowMs
            let encData = try MessageCrypto.encryptAttachment(sessionKey: sessionKey, data: data, roomId: session.roomId, ts: ts)
            let upload = try await AttachmentAPI.upload(roomId: session.roomId, mimeType: "image/jpeg", data: encData, token: token)
            let attMeta = "{\"f\":{\"attId\":\"\(upload.attId)\",\"name\":\"image.jpg\",\"size\":\(data.count),\"mime\":\"image/jpeg\"}}"
            let plainMeta = "{\"attId\":\"\(upload.attId)\",\"mime\":\"image/jpeg\",\"size\":\(data.count)}"
            let targetSeq = viewModel.nextSeq
            let encMsg = try MessageCrypto.encryptMessage(sessionKey: sessionKey, plaintext: attMeta, roomId: session.roomId, seq: targetSeq, ts: ts)
            let r = try await ChatAPI.send(session.roomId, iv: encMsg.iv, cipher: encMsg.ct, seq: targetSeq, ts: ts, kind: "attachment", meta: plainMeta, token: token)
            let attInfo = DecryptedMsg.AttachmentInfo(attId: upload.attId, name: "image.jpg", size: data.count, mime: "image/jpeg")
            viewModel.messages.append(DecryptedMsg(id: r.id, seq: r.seq, label: "我", mine: true, text: "📷 图片", ts: r.ts, kind: "attachment", att: attInfo, isRead: true))
            viewModel.nextSeq = r.seq; viewModel.updatePreview()
        } catch { errorMessage = "附件发送失败: \(error.localizedDescription)" }
    }
}

// MARK: - 辅助
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ p: ImagePicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage { parent.image = img }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct ToastModifier: ViewModifier {
    let message: String; let show: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if show {
                Text(message).font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(.systemBackground).opacity(0.95)).cornerRadius(8).shadow(radius: 4)
                    .transition(.opacity).animation(.easeInOut, value: show)
                    .position(x: UIScreen.main.bounds.width/2, y: UIScreen.main.bounds.height/2)
            }
        }
    }
}
extension View { func toast(message: String, show: Bool) -> some View { modifier(ToastModifier(message: message, show: show)) } }

// MARK: - 语音播放器缓存（单例，避免同时播放多个）
actor AVAudioPlayerCache {
    private var player: AVAudioPlayer?
    private var activeURL: URL?
    
    func play(_ url: URL, duration: Int) async {
        if activeURL == url, let player = player, player.isPlaying {
            player.pause()
            activeURL = nil
            self.player = nil
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            activeURL = url
            self.player = p
            try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000)
            if activeURL == url {
                p.stop()
                activeURL = nil
                self.player = nil
            }
        } catch {}
    }
}

struct MessageBubbleView: View {
    let msg: DecryptedMsg
    let onCopy: () -> Void
    let onDelete: (() -> Void)?
    let onForward: (() -> Void)?
    let isStarred: Bool
    let onStar: () -> Void
    let onPlayVoice: (() -> Void)?
    /// 账号聊天传入(图片/视频/文件附件的解密渲染上下文); 临时/邀请聊天附件不支持, 留 nil 走纯文本
    var attachmentContext: AttachmentContext? = nil
    /// 图片保存到相册
    var onSaveImage: (() -> Void)? = nil
    /// 文件附件分享(点击文件卡片触发)
    var onShareFile: ((URL) -> Void)? = nil
    /// 引用此消息（仅非附件）
    var onQuote: ((DecryptedMsg) -> Void)? = nil

    /// 该消息是否渲染附件媒体(图片/视频/文件)
    private var showsMedia: Bool {
        guard msg.kind == "attachment", let att = msg.att, attachmentContext != nil else { return false }
        return att.mime.hasPrefix("audio/") == false   // 语音保持文本气泡+点按播放
    }

    /// 气泡内的引用头(引用回复)
    private func quoteHeader(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(msg.mine ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
                .frame(width: 2.5)
            Text(text.count > 60 ? String(text.prefix(60)) + "…" : text)
                .font(.caption2)
                .lineLimit(2)
                .foregroundStyle(msg.mine ? Color.white.opacity(0.85) : Color.secondary)
        }
        .padding(.vertical, 2).padding(.horizontal, 5)
        .background((msg.mine ? Color.white : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    var body: some View {
        HStack {
            if msg.mine { Spacer(minLength: 60) }
            VStack(alignment: msg.mine ? .trailing : .leading, spacing: 3) {
                if !msg.mine { Text(msg.label).font(.caption2).foregroundStyle(.secondary) }
                if showsMedia {
                    if let ctx = attachmentContext, let att = msg.att {
                        AttachmentMediaView(msg: msg, roomId: ctx.roomId, sessionKey: ctx.sessionKey,
                                            token: ctx.token, onShareFile: onShareFile)
                    } else {
                        Text(msg.text)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        if let q = msg.quoteText, !q.isEmpty {
                            quoteHeader(q)
                        }
                        Text(msg.text)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(msg.mine ? Color.accentColor.opacity(0.9) : Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(msg.mine ? .white : .primary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 4) {
                    Text(TimeUtil.formatTime(msg.ts)).font(.caption2).foregroundStyle(Color(.tertiaryLabel))
                    if msg.mine {
                        Image(systemName: msg.isRead ? "checkmark.circle.fill" : "circle").font(.caption2)
                            .foregroundStyle(msg.isRead ? Color.accentColor : Color.secondary)
                    }
                }
            }
            .contextMenu {
                if msg.text.count > 0 { Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") } }
                if msg.att?.mime.hasPrefix("image/") == true, let save = onSaveImage {
                    Button { save() } label: { Label("保存到相册", systemImage: "square.and.arrow.down.on.square") }
                }
                // 引用此消息 (仅非附件消息)
                if msg.kind == "msg" {
                    Button { onQuote?(msg) } label: { Label("引用", systemImage: "quote.bubble") }
                }
                Button { onStar() } label: { Label(isStarred ? "取消收藏" : "收藏", systemImage: isStarred ? "star.fill" : "star") }
                if let onForward = onForward { Button { onForward() } label: { Label("转发", systemImage: "arrowshape.turn.up.right") } }
                if msg.mine {
                    if let onDelete = onDelete { Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") } }
                }
            }
            if !msg.mine { Spacer(minLength: 60) }
        }
        .onTapGesture {
            if let mime = msg.att?.mime, mime.hasPrefix("audio/"), let fn = onPlayVoice { fn() }
        }
    }
}