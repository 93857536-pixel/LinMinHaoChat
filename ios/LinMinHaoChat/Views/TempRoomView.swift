import SwiftUI

/// 临时聊天入口:发起新房间 或 粘贴分享链接加入
struct TempRoomView: View {
    @State private var pasteURL = ""
    @State private var isCreating = false
    @State private var createError: String?
    @State private var activeSession: TempRoomSession?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await createRoom() }
                } label: {
                    HStack {
                        Label("发起临时聊天", systemImage: "plus.circle.fill")
                            .foregroundStyle(.white)
                        Spacer()
                        if isCreating { ProgressView().tint(.white) }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.accentColor)
                .disabled(isCreating)
            } footer: {
                Text("创建后生成分享链接,密钥藏在链接里(#k=)不经过服务器,双方加入即可加密聊天。")
            }

            Section("加入聊天") {
                TextField("粘贴分享链接", text: $pasteURL, axis: .vertical)
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("加入") {
                    joinRoom()
                }
                .disabled(pasteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let createError {
                Section {
                    Text(createError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("临时聊天")
        .navigationDestination(item: $activeSession) { session in
            ChatView(session: session)
        }
    }

    private func createRoom() async {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let r: TempAPI.CreateResult = try await TempAPI.create()
            let key = SessionKeyUtil.generate()
            activeSession = TempRoomSession(roomId: r.roomId, sessionKey: key, isCreator: true)
        } catch {
            createError = "创建失败:\(error.localizedDescription)"
        }
    }

    private func joinRoom() {
        let trimmed = pasteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let parsed = SessionKeyUtil.parseShareURL(url) else {
            createError = "链接格式不正确:需要包含 #k= 会话密钥的临时聊天分享链接"
            return
        }
        createError = nil
        activeSession = TempRoomSession(roomId: parsed.roomId, sessionKey: parsed.key, isCreator: false)
    }
}
