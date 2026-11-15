import Foundation

/// 应用环境配置。
/// 后端端点由 NetworkChannel 决定(双通道,桌面方案 linminhao-chat-双通道直连方案.md):
///   domestic: 112.126.79.9 直连 443(自签证书 + SPKI pinning, 国内单跳 30-60ms)
///   intl:     chat.linminhao.top(Cloudflare, 海外 200-500ms)
/// host/apiBase/wsBase 全部跟随当前活动通道; 探测完成前默认 intl, 与旧行为一致。
enum AppEnvironment {
    /// 当前活动后端主机(跟随 NetworkChannel)
    static var host: String { NetworkChannel.shared.activeChannel.host }
    /// REST API 基址
    static var apiBase: String { "https://\(host)/api" }
    /// WebSocket 基址(join 返回的 wsUrl 为准, 这里仅兜底)
    static var wsBase: String { "wss://\(host)/ws" }

    /// 开发期可覆盖为本地后端(仅 Debug 构建生效; Release 永远走生产通道)。
    #if DEBUG
    static var apiBaseURL: String {
        if let v = UserDefaults.standard.string(forKey: "lmh.dev.apiBase"), !v.isEmpty { return v }
        return apiBase
    }
    #else
    static var apiBaseURL: String { apiBase }
    #endif
}
