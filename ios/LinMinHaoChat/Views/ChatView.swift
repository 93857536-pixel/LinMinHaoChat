import SwiftUI
import UIKit
import CryptoKit

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
                if let ips = viewModel.onlineIps {
                    Text("\(ips) 个IP在线").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
            Divider()
            
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
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.messages) { msg in
                                MessageBubbleView(msg: msg, onCopy: { copyToClipboard(msg.text) },
                                    onDelete: viewModel.messages.contains(where: { $0.id == msg.id }) ? { viewModel.deleteMessage(msg.id) } : nil)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        if let last = viewModel.messages.last {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            
            Divider()
            
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
                // 图片按钮
                Button { showPicker = true } label: {
                    Image(systemName: "photo").font(.system(size: 20)).frame(width: 38, height: 38).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                
                // 文本输入
                TextField("加密消息", text: $inputText, axis: .vertical).lineLimit(1...5).focused($inputFocused).lmhChatInputBubble()
                
                // 发送按钮
                Button {
                    if let img = selectedImage {
                        selectedImage = nil
                        Task { await sendAttachment(img) }
                        return
                    }
                    let text = inputText; inputText = ""
                    Task { await viewModel.send(text) }
                } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 18)).frame(width: 38, height: 38)
                        .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                }.disabled((inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedImage == nil) || isSending)
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle("加密聊天").navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }.onDisappear { viewModel.leave() }
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
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text; copiedMsgId = "copied"
    }
    
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

struct MessageBubbleView: View {
    let msg: DecryptedMsg
    let onCopy: () -> Void
    let onDelete: (() -> Void)?
    
    var body: some View {
        HStack {
            if msg.mine { Spacer(minLength: 60) }
            VStack(alignment: msg.mine ? .trailing : .leading, spacing: 3) {
                if !msg.mine { Text(msg.label).font(.caption2).foregroundStyle(.secondary) }
                Text(msg.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(msg.mine ? Color.accentColor.opacity(0.9) : Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(msg.mine ? .white : .primary)
                    .textSelection(.enabled)
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
                if msg.mine {
                    if let onDelete = onDelete { Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") } }
                }
            }
            if !msg.mine { Spacer(minLength: 60) }
        }
    }
}