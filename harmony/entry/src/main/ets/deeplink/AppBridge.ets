/**
 * AppBridge — @capacitor/app 兼容桥(鸿蒙端:深链)。
 */
import { common } from '@kit.AbilityKit';
import { K_LAUNCH_URL } from '../common/Consts';

interface AppPayload {
  url?: string;
  isActive?: boolean;
  name?: string;
  buildId?: string;
  version?: string;
}

export class AppHandler {
  private handler: (ok: boolean, payload: AppPayload, errMsg?: string) => void;
  constructor(handler: (ok: boolean, payload: AppPayload, errMsg?: string) => void) {
    this.handler = handler;
  }
  invoke(ok: boolean, payload: AppPayload, errMsg?: string): void {
    this.handler(ok, payload, errMsg);
  }
}

export class AppBridge {
  context: common.UIAbilityContext;
  onNewDeepLink: ((uri: string) => void) | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  setNewLinkForwarder(fn: ((uri: string) => void) | null): void {
    this.onNewDeepLink = fn;
  }

  dispatch(method: string, options: Record<string, Object>, done: AppHandler): void {
    switch (method) {
      case 'getLaunchUrl': {
        const url: string = AppStorage.get<string>(K_LAUNCH_URL) ?? '';
        done.invoke(true, { url: url });
        return;
      }
      case 'getState': {
        done.invoke(true, { isActive: true });
        return;
      }
      case 'getInfo': {
        done.invoke(true, { name: 'LinMinHaoChat', buildId: 'harmony', version: '1.9.16' });
        return;
      }
      case 'exitApp': {
        done.invoke(true, {});
        return;
      }
      default:
        done.invoke(true, {});
        return;
    }
  }
}
