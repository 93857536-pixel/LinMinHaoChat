/**
 * PnsAuth — 阿里云号码认证(一键登录)桥插件(鸿蒙端:优雅降级)。
 *
 * 调研结论(见 docs/bridge-protocol.md §5):阿里云号码认证**无 HarmonyOS NEXT 官方 SDK**,
 * 服务端 /api/pns/phone-check 走阿里云 GetMobile(平台无关),而鸿蒙端暂无合规 spToken 来源。
 * 故 v1 鸿蒙端**一键登录降级**为短信/邮箱验证码登录:本插件恒返回「不可用」,
 * 前端 Login 页 pnsAvailable()=false → 自动隐藏「本机号码一键登录」按钮(已有降级路径,天然闭环)。
 *
 * ⚠️ 桥接口与 Android/iOS 逐字对齐(isAvailable/checkEnv/startLogin 三方法 + 返回 shape),
 *   升级路径:待阿里云出鸿蒙 PNS SDK 或接个推/极光一键认证,替换本文件降级桩即可,桥协议不变。
 */
export interface PnsHandler {
  (ok: boolean, payload: Record<string, Object>, errMsg?: string): void;
}

export class PnsAuth {
  /** 与前端 registerPlugin('PnsAuth') 方法面对齐的分发入口 */
  dispatch(method: string, options: Record<string, Object>, done: PnsHandler): void {
    switch (method) {
      case 'isAvailable':
        // 鸿蒙暂无阿里云 PNS SDK → 不可用。前端据此隐藏一键登录按钮。
        done(true, { available: false });
        return;
      case 'checkEnv':
        // 预检同样不可用;给出中文原因供前端文案。
        done(true, {
          available: false,
          error: 'HarmonyOS 暂不支持一键登录(缺少号码认证 SDK),请改用验证码登录'
        });
        return;
      case 'startLogin':
        // 即便前端误调,也稳妥拒绝,引导走验证码。reject(中文可读原因)→ JS 侧 catch 展示。
        done(false, {}, '当前系统暂不支持一键登录,请使用下方验证码登录');
        return;
      default:
        done(false, {}, `PnsAuth.${method} 未实现`);
        return;
    }
  }
}
