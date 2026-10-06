import Foundation

// MARK: - 邀请聊天 ViewModel —— 参照 web InviteChat.tsx 逻辑
@MainActor
final class InviteChatViewModel: ObservableObject {
    // MARK: - Published State
    @Published var status: Status = .loading
    @Published var needsCode = false
    
    // MARK: - Properties
    private let inviteId: String
    private var info: RoomInfo?
    private var token: String?
    
    enum Status {
        case loading
        case error(String)
        case roomInfo(RoomInfo)
        case connected
    }
    
    struct RoomInfo {
        let roomId: String
        let roomName: String
        let createdBy: Int
        let createdByLabel: String
        let createdAt: Int64
        let expiresAt: Int64
        let expiresInSec: Int
        let needsCode: Bool
    }
    
    // MARK: - Init
    init(inviteId: String) {
        self.inviteId = inviteId
    }
    
    // MARK: - Public Methods
    func verify() async {
        status = .loading
        do {
            let result = try await InviteChatAPI.verify(inviteId, code: nil)
            guard result.ok else {
                status = .error("邀请无效或已过期")
                return
            }
            
            // 检查是否需要密码
            needsCode = result.codeRequired
            
            // 创建房间信息
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            info = RoomInfo(
                roomId: result.roomId,
                roomName: result.nameEnc ?? "",
                createdBy: result.createdBy ?? 0,
                createdByLabel: "未知",
                createdAt: result.createdAt,
                expiresAt: result.expiresAt,
                expiresInSec: max(0, Int(result.expiresAt - now) / 1000),
                needsCode: result.codeRequired
            )
            
            if needsCode {
                status = .roomInfo(info!)
            } else {
                // 自动加入
                await join(code: nil)
            }
        } catch {
            status = .error("验证失败:\(error.localizedDescription)")
        }
    }
    
    func join(code: String?) async {
        guard let info = info else { return }
        status = .loading
        
        do {
            let result = try await InviteChatAPI.verify(inviteId, code: code)
            if result.ok {
                token = result.joinToken
                status = .connected
            } else {
                status = .error("加入失败")
            }
        } catch {
            status = .error("加入失败:\(error.localizedDescription)")
        }
    }
    
    func showError(error: Error?) {
        if let error = error {
            status = .error(error.localizedDescription)
        }
    }
}

// MARK: - InviteChatAPI

enum InviteChatAPI {
    struct VerifyResult: Decodable {
        let ok: Bool
        let roomId: String
        let nameEnc: String?
        let createdAt: Int64
        let expiresAt: Int64
        let createdBy: Int?
        let codeRequired: Bool
        let joinToken: String?
    }
    
    static func verify(_ inviteId: String, code: String?) async throws -> InviteChatAPI.VerifyResult {
        var path = "/invite/\(inviteId)"
        if let code = code {
            path += "?code=\(code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        }
        return try await APIClient.request(path)
    }
}
