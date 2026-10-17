package com.linminhao.chat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import com.mobile.auth.gatewayauth.PhoneNumberAuthHelper;
import com.mobile.auth.gatewayauth.ResultCode;
import com.mobile.auth.gatewayauth.TokenResultListener;
import com.mobile.auth.gatewayauth.manager.FeatureManager;
import com.mobile.auth.gatewayauth.model.TokenRet;

/**
 * 阿里云号码认证(一键登录)原生插件。
 *
 * 为什么必须原生:SDK 是 Java/so 组件(PhoneNumberAuthHelper),WebView 里跑不了。
 * 与 iOS 端 PNSAuthManager.swift 同款约定:
 *   - AppSecret 经 buildConfigField 注入(来源 android/pns.properties,本机私有,不进 git),
 *     方案 = chatapp-android / FC220000013715102 / 包名 com.linminhao.chat
 *   - 前端拿到 spToken 后交给服务端 POST /api/pns/phone-check(GetMobile,平台无关),
 *     服务端换号 + 登录/注册,返回 JWT。AppSecret 只用于客户端拉起运营商授权页。
 *
 * 事件映射(与 iOS 教训同款,勿回退):onTokenSuccess 是**多事件**的——
 *   CODE_START_AUTHPAGE_SUCCESS(授权页已唤起)= 中间态,只忽略不完成;
 *   仅 CODE_SUCCESS(拿到 token)才是终态。终态后才 quitLoginPage + setAuthListener(null)。
 *
 * 前端调用见 web/src/mobile/pns-auth.ts(registerPlugin('PnsAuth'))。
 */
@CapacitorPlugin(name = "PnsAuth")
public class PnsAuthPlugin extends Plugin {

    private PhoneNumberAuthHelper helper;
    private PluginCall pendingCall;

    /** 插件是否可用(构建时注入了有效 AppSecret)。 */
    @PluginMethod
    public void isAvailable(PluginCall call) {
        JSObject ret = new JSObject();
        boolean ok = BuildConfig.PNS_ENABLED && BuildConfig.PNS_APP_SECRET.length() > 0;
        ret.put("available", ok);
        call.resolve(ret);
    }

    /** 环境预检(SIM + 蜂窝网络 + 运营商可识别)。不可用不应拒绝,前端据此给文案。 */
    @PluginMethod
    public void checkEnv(PluginCall call) {
        JSObject ret = new JSObject();
        try {
            initIfNeeded();
            boolean available = helper.checkEnvAvailable();
            ret.put("available", available);
            call.resolve(ret);
        } catch (Exception e) {
            ret.put("available", false);
            ret.put("error", String.valueOf(e.getMessage()));
            call.resolve(ret);
        }
    }

    /**
     * 拉起运营商授权页取号。
     * 成功 → {ok:true, token: spToken, vendor};失败/用户取消 → reject(中文可读原因)。
     * ⚠️ 重复调用(授权页还开着)会拒绝,前端按钮需带 busy 态。
     */
    @PluginMethod
    public void startLogin(PluginCall call) {
        if (pendingCall != null) {
            call.reject("一键登录进行中,请先完成当前授权");
            return;
        }
        try {
            initIfNeeded();
            if (!helper.checkEnvAvailable()) {
                call.reject("当前设备无法一键登录:请确认已插 SIM 卡且开启蜂窝网络(可改用下方验证码登录)");
                return;
            }
            pendingCall = call;
            helper.getLoginToken(getActivity(), 5000);
        } catch (Exception e) {
            pendingCall = null;
            call.reject("一键登录启动失败: " + e.getMessage());
        }
    }

    /* ---------------- 内部 ---------------- */

    private void initIfNeeded() {
        if (helper != null) return;
        // 对齐 iOS 端 2026-10-01 的「网络连接已中断」根治措施:
        // 跳过 SDK 配置/埋点等非核心网络请求,不影响一键登录核心链路。
        FeatureManager.getInstance().put(FeatureManager.FEATURE_KEY_REDUCE_NETWORKACCESS, "true");
        helper = PhoneNumberAuthHelper.getInstance(getContext(), new TokenResultListener() {
            @Override
            public void onTokenSuccess(String ret) {
                handleToken(ret, false);
            }

            @Override
            public void onTokenFailed(String ret) {
                handleToken(ret, true);
            }
        });
        // 关闭 SDK 日志上传(服务端 /api/diag/upload 已有自有诊断通道,无需 SDK 再传)
        helper.getReporter().setLoggerEnable(false);
        helper.setAuthSDKInfo(BuildConfig.PNS_APP_SECRET);
    }

    private void handleToken(String raw, boolean failed) {
        PluginCall call = pendingCall;
        if (call == null) return;
        TokenRet ret;
        try {
            ret = TokenRet.fromJson(raw);
        } catch (Exception e) {
            ret = null;
        }
        String code = ret != null ? ret.getCode() : null;
        String msg = ret != null && ret.getMsg() != null ? ret.getMsg() : raw;

        // 中间态:授权页已唤起,继续等终态(不完成 call,否则 token 还没拿到)
        if (!failed && ResultCode.CODE_START_AUTHPAGE_SUCCESS.equals(code)) {
            return;
        }

        pendingCall = null;
        try {
            helper.quitLoginPage();
        } catch (Exception ignore) {
        }
        helper.setAuthListener(null);

        if (!failed && ResultCode.CODE_SUCCESS.equals(code) && ret.getToken() != null && ret.getToken().length() > 0) {
            JSObject out = new JSObject();
            out.put("ok", true);
            out.put("token", ret.getToken());
            out.put("vendor", String.valueOf(ret.getVendorName()));
            call.resolve(out);
            return;
        }

        call.reject(friendlyReason(code, msg));
    }

    /** SDK 错误码 → 中文可读原因(与 iOS 端返回码表口径一致) */
    private String friendlyReason(String code, String rawMsg) {
        if (code == null) {
            return "一键登录失败: " + rawMsg;
        }
        switch (code) {
            case "600007": return "未检测到 SIM 卡";
            case "600012": return "蜂窝网络未开启";
            case "600013": return "运营商不可识别";
            case "600017": return "App 认证信息解密失败,请联系管理员(方案/密钥不匹配)";
            case "600020": return "运营商服务维护中,请稍后再试";
            case "601004": return "今日认证次数已达上限";
            case "601006": return "当前终端环境不支持一键登录";
            case "600010":
            case "600011":
            case "600015":
            case "600025": return "网络连接已中断,请检查网络后重试";
            case "700002":
            case "700003":
            case "700004": return "用户未完成授权";
            default:
                return "一键登录失败(" + code + "): " + rawMsg;
        }
    }
}
