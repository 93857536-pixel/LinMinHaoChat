import Foundation

/// 应用环境配置。
/// 正式后端固定为 chat.linminhao.top —— 用户不需要知道、也不需要输入这个地址,
/// App 内部自动连接(产品定位第五条)。
/// 2026-10-05: 后端从根域名迁移到 chat 子域名(根域名不再承载应用服务)。
enum AppEnvironment {
    /// 生产后端主机
    static let host = "chat.linminhao.top"
    /// REST API 基址
    static let apiBase = "https://\(host)/api"
    /// WebSocket 基址(join 返回的 wsUrl 为准,这里仅兜底)
    static let wsBase = "wss://\(host)/ws"

    /// 开发期可覆盖为本地后端(仅 Debug 构建生效;Release 永远走生产)。
    #if DEBUG
    static var apiBaseURL: String {
        if let v = UserDefaults.standard.string(forKey: "lmh.dev.apiBase"), !v.isEmpty { return v }
        return apiBase
    }
    #else
    static var apiBaseURL: String { apiBase }
    #endif
}
