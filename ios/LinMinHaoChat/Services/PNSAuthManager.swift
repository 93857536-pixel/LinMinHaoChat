//
//  PNSAuthManager.swift
//  LinMinHaoChat
//
//  阿里云号码认证(一键登录)封装:
//  - 初始化:setAuthSDKInfo(传 AppSecret,一次即可)
//  - 检查环境:checkEnvAvailableWithAuthType
//  - 一键登录:getLoginTokenWithTimeout 弹运营商授权页 → 回调返回 SpToken
//  - 拿到 SpToken 后调服务端 /api/pns/phone-check 换手机号登录
//
//  2026-08-20 诊断改造:print → os.Logger(统一日志,log stream 可可靠捕获;
//  devicectl --console 抓不到 Swift print 输出)。setupIfNeeded 加 5s 超时兜底,
//  避免 SDK 回调不触发时 withCheckedContinuation 永久挂起(表现为点按钮永久转圈)。
//

import UIKit
import os

/// 一键登录流程结果
enum PNSLoginResult {
    case success(spToken: String)
    case userCancel           // 用户点了返回/切换,回退验证码登录
    case notSupported(reason: String)  // 无SIM卡/Wi-Fi/运营商不支持
    case failed(reason: String)
}

final class PNSAuthManager {

    static let shared = PNSAuthManager()

    /// 服务端配置的 AppSecret(仅客户端 SDK 鉴权用,非敏感签名密钥)
    /// 2026-08-19:重建方案(FC220000013450028, Bundle ID=com.linminhao.chat)后更新的 AppEncryptInfo
    private let appSecret = "Ce27LVLzFbA28lXg9VrtL8mQAvaTWf036ZSBgWKZ2OIUSlQ9SN3TB0dWdVBRU+70j+VhaXabT9EwaCo87a4XcqVtj1Cuxr2Vg/6kUwZCYaoUYbtKxNAX9zitN6YzsdWKRKp9AL63AKr+Ubj50OGcwPO5KROh30uo42k60v3tyyyQQw/GG/+KdzJ74Q5hIXulKYp9BQ9WX1BDK/+4YLqswFbOhDnPV2NERHsEEFJ7vqsJ7yQ4zHAzP+eNn40tU3sQxRPEQo1FWH4="

    /// 已鉴权标志(SDK 要求 app 生命周期内调用一次)
    private var didInit = false

    /// 统一日志(os.Logger,log stream 可捕获;devicectl --console 抓不到 print)
    private let pnsLogger = Logger(subsystem: "com.linminhao.chat", category: "PNS")

    private func pnsLog(_ msg: String) {
        pnsLogger.info("\(msg, privacy: .public)")
    }

    private init() {}

    /// 初始化 SDK(异步,失败不阻塞后续流程;5s 超时兜底防止永久挂起)
    func setupIfNeeded(completion: ((Bool) -> Void)? = nil) {
        guard !didInit else {
            pnsLog("[PNS] setupIfNeeded: didInit=true,直接放行")
            completion?(true)
            return
        }
        pnsLog("[PNS] setupIfNeeded: 首次初始化,调 setAuthSDKInfo")
        var finished = false
        let finishOnce: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { completion?(ok) }
        }
        TXCommonHandler.sharedInstance().setAuthSDKInfo(appSecret) { [weak self] result in
            let dict = result as? [String: Any] ?? [:]
            let code = (dict["resultCode"] as? String) ?? ""
            let ok = code == PNSCodeSuccess
            self?.pnsLog("[PNS] setAuthSDKInfo 回调 resultCode=\(code) dict=\(String(describing: dict))")
            if ok { self?.didInit = true }
            finishOnce(ok)
        }
        // 5s 超时兜底:SDK 回调不触发时不再永久卡死
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if !finished {
                self?.pnsLog("[PNS] setAuthSDKInfo 5s 超时无回调!继续流程(SDK 可能异常)")
                finishOnce(false)
            }
        }
    }

    /// 检查当前环境是否支持一键登录(蜂窝网络 + SIM 卡 + 运营商)
    /// 加 10s 超时保护:SDK 回调异常不返回时快速给出可读错误,不再静默干等外层 15s 兜底
    func checkEnvironment(completion: @escaping (Bool, String?) -> Void) {
        pnsLog("[PNS] checkEnvironment: 开始环境预检")
        var finished = false
        func finishOnce(_ ok: Bool, _ reason: String?) {
            guard !finished else { return }
            finished = true
            completion(ok, reason)
        }
        TXCommonHandler.sharedInstance().checkEnvAvailable(with: .loginToken) { [weak self] result in
            guard !finished else { return }
            let code = (result?["resultCode"] as? String) ?? ""
            self?.pnsLog("[PNS] checkEnvAvailable 回调 resultCode=\(code) dict=\(String(describing: result ?? [:]))")
            if code == PNSCodeSuccess {
                finishOnce(true, nil)
            } else {
                finishOnce(false, Self.describe(code: code))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard !finished else { return }
            self?.pnsLog("[PNS] checkEnvironment 10s 超时无回调")
            finishOnce(false, "环境检测超时,请确认已开启移动数据(蜂窝网络)后重试")
        }
    }

    /// 官方选调接口:提前加速授权页弹起 + 预取号(官方文档:getLoginToken 内部会自动先调本接口,
    /// 有明显等待;弱信号/蜂窝差时易 600015 超时,表现为"点了没反应")。
    /// 进登录页/手机号 tab 时后台调用,点按钮时授权页立即弹出。失败不阻塞主流程(仅记日志)。
    func accelerateLoginPage() async {
        pnsLog("[PNS] accelerateLoginPage: 预取号(后台加速)")
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var done = false
            let finish: (Bool) -> Void = { ok in
                guard !done else { return }
                done = true
                cont.resume(returning: ok)
            }
            TXCommonHandler.sharedInstance().accelerateLoginPage(withTimeout: 3.0) { result in
                let code = (result["resultCode"] as? String) ?? ""
                finish(code == PNSCodeSuccess)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(false) }
        }
        pnsLog("[PNS] accelerateLoginPage: 完成(结果仅用于日志,不阻塞流程)")
    }

    /// 发起一键登录:弹运营商授权页,成功后回调 SpToken
    ///  - 用户在授权页点返回/切换 → userCancel(UI 层回退到验证码登录)
    ///  - 15 秒兜底超时:SDK 回调不触发(如 Wi-Fi 下运营商无响应)时给出可读提示,避免无限转圈
    ///  - ⚠️ SDK 回调是「多事件」:授权页控件点击(700000-700004)、唤起成功(600001)等中间事件
    ///    都会触发回调;只有终态(600000/600002/600011/600015/700000/700001)才允许 resume
    ///    continuation。必须用 hasCompleted 标志保证 completion 只调用一次,否则
    ///    CheckedContinuation 双重 resume → SIGTRAP 崩溃。
    func startOneTapLogin(from controller: UIViewController,
                          completion: @escaping (PNSLoginResult) -> Void) {
        pnsLog("[PNS] startOneTapLogin: 入口")
        var hasCompleted = false
        let completeOnce: (PNSLoginResult) -> Void = { [weak self] result in
            guard !hasCompleted else { return }
            hasCompleted = true
            self?.pnsLog("[PNS] 终态回调: \(result)")
            completion(result)
        }
        let guardTimeout = DispatchWorkItem { [weak self] in
            // 兜底:如果到这里回调还没触发,给超时提示
            self?.pnsLog("[PNS] 15s 兜底超时触发!回调未到达")
            if self != nil {
                completeOnce(.notSupported(reason: "一键登录超时,请确认已开启移动数据(蜂窝网络)后重试"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: guardTimeout)

        // 环境预检(不通过直接给原因,不弹页)
        checkEnvironment { [weak self] ok, reason in
            guard let self else { return }
            guard ok else {
                guardTimeout.cancel()
                self.pnsLog("[PNS] 环境预检不通过: \(reason ?? "未知原因")")
                completeOnce(.notSupported(reason: reason ?? "当前网络环境不支持一键登录"))
                return
            }
            self.pnsLog("[PNS] 环境预检通过,弹授权页 getLoginTokenWithTimeout")
            // 弹授权页。官方 Demo 要求传入 TXCustomModel 实例(不能传 nil):
            //   TXCustomModel *model = [[TXCustomModel alloc] init];
            // 传 nil 走 SDK 内部默认 UI,在部分 iOS 版本上点击登录按钮可能无回调。
            // checkBoxIsChecked: 协议 checkbox 默认勾选(官方注释:默认NO,不勾选时
            //   点击登录按钮 SDK 不会获取 token → 表现为"点了没反应")。
            let model = TXCustomModel()
            model.checkBoxIsChecked = true
            TXCommonHandler.sharedInstance().getLoginToken(withTimeout: 3.0,
                                                           controller: controller,
                                                           model: model) { [weak self] result in
                guardTimeout.cancel()
                let dict = result as? [String: Any] ?? [:]
                let code = (dict["resultCode"] as? String) ?? ""
                self?.pnsLog("[PNS] getLoginToken 回调 resultCode=\(code) dict=\(String(describing: dict))")
                switch code {
                case PNSCodeSuccess:
                    let token = (dict["token"] as? String) ?? ""
                    self?.pnsLog("[PNS] 获取 token 成功 token=\(token.isEmpty ? "空!" : "\(token.prefix(10))...")")
                    if token.isEmpty {
                        completeOnce(.failed(reason: "获取授权令牌失败,请重试"))
                    } else {
                        completeOnce(.success(spToken: token))
                    }
                case PNSCodeLoginControllerClickCancel,
                     PNSCodeLoginControllerClickChangeBtn:
                    // 用户主动返回/切换 → 回退验证码登录(终态)
                    completeOnce(.userCancel)
                case PNSCodeNoSIMCard:
                    completeOnce(.notSupported(reason: "未检测到 SIM 卡,请使用验证码登录"))
                case PNSCodeNoCellularNetwork:
                    completeOnce(.notSupported(reason: "蜂窝网络未开启,请切换到移动数据后重试"))
                case PNSCodeLoginControllerPresentSuccess:
                    // 600001 授权页唤起成功(中间事件,等待后续 token 回调,不 resume)
                    // ⚠️ 默认 checkbox 未勾选,点「同意」不会获取 token;这里默认勾选协议
                    TXCommonHandler.sharedInstance().setCheckboxIsChecked(true)
                    break
                case PNSCodeLoginControllerPresentFailed:
                    // 600002 授权页唤起失败(终态)
                    completeOnce(.failed(reason: "授权页唤起失败,请重试"))
                case PNSCodeLoginControllerClickLoginBtn:
                    // 700002 用户点击授权页登录按钮(中间事件,SDK 内部会继续获取 token)
                    // ⚠️ 诊断:打印 isChecked 确认 checkbox 状态(官方文档:未勾选则不取 token)
                    self?.pnsLog("[PNS] 700002 用户点击登录按钮 isChecked=\(String(describing: dict["isChecked"] ?? "nil"))")
                    break
                default:
                    // 700003 checkbox / 700004 协议等中间事件:不 resume,等终态
                    // 其他错误码视为失败
                    if let codeInt = Int(code), codeInt >= 700000 && codeInt < 710000 {
                        self?.pnsLog("[PNS] 中间事件 resultCode=\(code) 忽略(等终态)")
                        break
                    }
                    self?.pnsLog("[PNS] 失败 resultCode=\(code)")
                    completeOnce(.failed(reason: Self.describe(code: code)))
                }
            }
        }
    }

    /// 返回码可读文案
    static func describe(code: String) -> String {
        switch code {
        case PNSCodeNoSIMCard: return "未检测到 SIM 卡"
        case PNSCodeNoCellularNetwork: return "蜂窝网络未开启或不稳定,请开启移动数据"
        case PNSCodeUnknownOperator: return "无法识别运营商"
        case PNSCodeGetTokenFailed: return "获取令牌失败(600011,含运营商错误,重试或换验证码登录)"
        case PNSCodeGetMaskPhoneFailed: return "预取号失败,请重试"
        case PNSCodeInterfaceTimeout: return "运营商接口超时,请重试"
        case PNSCodeInterfaceDemoted: return "运营商维护中,功能暂不可用,请使用验证码登录"
        case PNSCodeInterfaceLimited: return "运营商调用次数已达上限,明日再试或使用验证码登录"
        case PNSCodePhoneBlack: return "该号码已被运营商管控(联通),请使用验证码登录"
        case PNSCodeCarrierChanged: return "SIM 卡已切换,请重试"
        case PNSCodeEnvCheckFail: return "当前设备环境不支持认证,请使用验证码登录"
        case PNSCodeGetOperatorInfoFailed: return "获取运营商配置失败"
        case PNSCodeDecodeAppInfoFailed: return "SDK 鉴权信息解析失败"
        case PNSCodeUnknownError: return "未知错误"
        default: return "错误码 \(code)"
        }
    }
}
