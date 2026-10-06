import SwiftUI

/// 收藏消息列表视图
struct StarredListView: View {
    @StateObject private var viewModel = StarredListViewModel()
    
    var body: some View {
        List {
            if viewModel.starredMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "star").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("暂无收藏消息")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Text("在聊天中长按消息选择\"收藏\"")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(viewModel.starredMessages) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.roomId).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(TimeUtil.formatTime(item.ts)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(item.previewText)
                            .font(.body)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await viewModel.unstarItem(item) }
                        } label: {
                            Label("取消收藏", systemImage: "star.slash")
                        }
                    }
                }
            }
        }
        .navigationTitle("收藏消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.loadStarred() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await viewModel.loadStarred()
        }
    }
}

/// 收藏消息视图模型
@MainActor
final class StarredListViewModel: ObservableObject {
    @Published var starredMessages: [StarredListItem] = []
    
    struct StarredListItem: Identifiable {
        let id: String
        let roomId: String
        let msgId: String
        let ts: Int64
        let previewText: String
    }
    
    func loadStarred() async {
        guard let token = AppState.shared.authToken else { return }
        do {
            let starred = try await StarredAPI.list(token: token)
            starredMessages = starred.map { item in
                let roomName = getRoomPreviewText(item.roomId, kind: item.kind, metaEnc: item.metaEnc)
                return StarredListItem(
                    id: item.id,
                    roomId: item.roomId,
                    msgId: item.id,
                    ts: item.ts,
                    previewText: roomName
                )
            }
        } catch {
            print("[StarredList] Failed to load: \(error)")
        }
    }
    
    func unstarItem(_ item: StarredListItem) async {
        guard let token = AppState.shared.authToken else { return }
        do {
            try await StarredAPI.unstar(item.msgId, token: token)
            starredMessages.removeAll { $0.id == item.id }
        } catch {
            print("[StarredList] Failed to unstar: \(error)")
        }
    }
    
    private func getRoomPreviewText(_ roomId: String, kind: String, metaEnc: String?) -> String {
        if kind == "attachment" {
            return "📷 图片附件"
        }
        return "房间: \(roomId.prefix(8))..."
    }
}