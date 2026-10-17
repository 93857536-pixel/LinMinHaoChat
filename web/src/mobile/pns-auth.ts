/**
 * 原生能力桥(主会话维护)—— 阿里云号码认证一键登录(Android)。
 *
 * ⚠️ 跨端硬约束:SDK 是 Java/so 组件(PhoneNumberAuthHelper),WebView 里跑不了,
 *    必须走 Capacitor 原生插件 PnsAuth(app/src/main/java/.../PnsAuthPlugin.java)。
 *    浏览器环境(isNativeShell()=false)一律返回不可用,UI 降级为验证码登录。
 *
 * 链路(与 iOS 端 PNSAuthManager 同款约定):
 *   1. checkEnv() 预检(SIM + 蜂窝 + 运营商),不可用 → 按钮置灰 + 文案
 *   2. startLogin() 拉起运营商授权页 → 用户同意 → 拿 spToken(一次性,几秒内有效)
 *   3. spToken 交给服务端 POST /api/pns/phone-check(GetMobile 换号,平台无关,iOS 已在生产验证)
 *      → 老号登录 / 新号自动注册 → 返回 JWT
 *
 * 密钥约定:AppSecret 经 android/pns.properties(本机私有,gitignore)→ BuildConfig 注入,
 *   绝不进前端/服务器 env.json 之外的位置。方案 = chatapp-android / FC220000013715102。
 */
import { registerPlugin } from '@capacitor/core';

interface PnsAuthPlugin {
  isAvailable(): Promise<{ available: boolean }>;
  checkEnv(): Promise<{ available: boolean; error?: string }>;
  /** 拉起授权页;成功 resolve {ok, token, vendor},失败/取消 reject(中文原因) */
  startLogin(): Promise<{ ok: true; token: string; vendor: string }>;
}

const PnsAuth = registerPlugin<PnsAuthPlugin>('PnsAuth');

/** 本端是否为原生壳(仅 Android Capacitor 壳内 PnsAuth 插件存在) */
export function pnsNativeShell(): boolean {
  const c = (globalThis as unknown as { Capacitor?: { isNativePlatform?: () => boolean } }).Capacitor;
  return !!(c && typeof c.isNativePlatform === 'function' && c.isNativePlatform());
}

/** 一键登录是否可用(构建时注入了有效 AppSecret) */
export async function pnsAvailable(): Promise<boolean> {
  if (!pnsNativeShell()) return false;
  try {
    const r = await PnsAuth.isAvailable();
    return !!r.available;
  } catch {
    return false;
  }
}

/** 环境预检结果 */
export interface PnsEnvResult {
  ok: boolean;
  reason?: string;
}

/** 拉起授权页取 spToken(一次性,勿缓存/勿重试) */
export async function pnsGetLoginToken(): Promise<{ token: string; vendor: string }> {
  const r = await PnsAuth.startLogin();
  return { token: r.token, vendor: r.vendor };
}
