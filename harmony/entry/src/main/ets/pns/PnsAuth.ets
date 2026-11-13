/**
 * PnsAuth — 阿里云号码认证(一键登录)桥插件(鸿蒙端:优雅降级)。
 */
interface PnsPayload {
  available?: boolean;
  error?: string;
}

export class PnsHandler {
  private handler: (ok: boolean, payload: PnsPayload, errMsg?: string) => void;
  constructor(handler: (ok: boolean, payload: PnsPayload, errMsg?: string) => void) {
    this.handler = handler;
  }
  invoke(ok: boolean, payload: PnsPayload, errMsg?: string): void {
    this.handler(ok, payload, errMsg);
  }
}

export class PnsAuth {
  dispatch(method: string, options: Record<string, Object>, done: PnsHandler): void {
    switch (method) {
      case 'isAvailable':
        done.invoke(true, { available: false });
        return;
      case 'checkEnv':
        done.invoke(true, {
          available: false,
          error: 'HarmonyOS 暂不支持一键登录(缺少号码认证 SDK),请改用验证码登录'
        });
        return;
      case 'startLogin':
        done.invoke(false, {}, '当前系统暂不支持一键登录,请使用下方验证码登录');
        return;
      default:
        done.invoke(false, {}, `PnsAuth.${method} 未实现`);
        return;
    }
  }
}
