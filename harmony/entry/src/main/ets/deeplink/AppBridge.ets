/**
 * AppBridge — @capacitor/app 兼容桥(鸿蒙端:深链)。
 *
 * 与前端 MobileApp.tsx 的 `@capacitor/app` 用法逐字对齐(见 docs/bridge-protocol.md §4):
 *   getLaunchUrl()            → { url: 冷启动深链 uri 或 '' }
 *   addListener('appUrlOpen') → 事件 { url } (热启动: App 已在前台时点链接)
 *
 * 深链来源(module.json5 skills 注册,与 iOS/Android 同款):
 *   ① lmhchat://invite/<id>#k=… / lmhchat://i|t|temp/<id>
 *   ② https://chat.linminhao.top/i|t/<id>#k=… , https://linminhao.top/i|t/<id>
 * EntryAbility 把冷启动 want.uri 写进 AppStorage(K_LAUNCH_URL);热启动由 onNewWant
 * 经 dispatcher.onDeepLink(uri) → 本插件 emit appUrlOpen。
 *
 * 解析(lmhchat→/i|/t、保留 fragment #k= 与 query ?account=/?roomCode=)由前端
 * web/src/mobile/deeplink.ts 的 parseDeepLink 完成(与 iOS InviteLinkParser 对齐),
 * 本插件只负责把原始 uri 交给 JS,不重复实现解析,避免两端口径漂移。
 */
import { common } from '@kit.AbilityKit';
import { K_LAUNCH_URL } from '../common/Consts';

export type AppHandler = (ok: boolean, payload: Record<string, Object>, errMsg?: string) => void;

export class AppBridge {
  private context: common.UIAbilityContext;
  /** 热启动转发器:由 EntryAbility.onNewWant 注入,指向 dispatcher.onDeepLink */
  private onNewDeepLink: ((uri: string) => void) | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** EntryAbility 注入热启动转发(桥与 want 生命周期解耦) */
  setNewLinkForwarder(fn: ((uri: string) => void) | null): void {
    this.onNewDeepLink = fn;
  }

  /** 分发入口(与 BridgeDispatcher 对齐)。addListener/removeListener 已由 dispatcher 处理,
   *  这里只管 promise 类方法:getLaunchUrl / getInfo / getState / exitApp … */
  dispatch(method: string, options: Record<string, Object>, done: AppHandler): void {
    switch (method) {
      case 'getLaunchUrl': {
        // 冷启动深链(EntryAbility.onCreate 存入 AppStorage);无深链则 ''(前端 handle(null) 自然跳过)
        const url: string = AppStorage.get<string>(K_LAUNCH_URL) ?? '';
        done(true, { url: url });
        return;
      }
      case 'getState': {
        done(true, { isActive: true });
        return;
      }
      case 'getInfo': {
        // 前端不用,给个最小实现
        done(true, { name: 'LinMinHaoChat', buildId: 'harmony', version: '1.9.16' });
        return;
      }
      case 'exitApp': {
        // @capacitor/app.exitApp 语义:结束应用。ArkTS 无对应公开「杀自身」API(系统自毁语义),
        // 前端 MobileApp 不用 exitApp;稳妥地「成功空返回」, 避免 reject 崩流程。
        done(true, {});
        return;
      }
      default:
        // 其余 App 方法(前端未用):稳妥地「成功空返回」,避免前端 reject 崩流程
        done(true, {});
        return;
    }
  }
}
