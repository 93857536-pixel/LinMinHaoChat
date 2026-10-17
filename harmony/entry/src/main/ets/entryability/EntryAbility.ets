/**
 * EntryAbility — LinMinHaoChat HarmonyOS 入口(UIAbility, Stage 模型)。
 *
 * 职责(与前端壳解耦, 只负责深链与 AppStorage 初始化):
 *   - onCreate: 初始化 AppStorage(K_LAUNCH_URL / K_PENDING_DEEPLINK), 解析冷启动深链
 *   - onNewWant: 解析热启动深链 → 写 K_PENDING_DEEPLINK, 由 Index 页 onVisible 转发给桥
 *
 * 深链来源(module.json5 skills 注册, 与 iOS/Android 同款):
 *   lmhchat://invite|i|t|temp/<id>#k=…  及  https://chat.linminhao.top/i|t/<id>、https://linminhao.top/i|t/<id>
 * 解析(lmhchat→/i|/t、保留 #k= 与 ?account=/?roomCode=)统一交给前端 web/src/mobile/deeplink.ts,
 * Ability 只判断"是否深链"并透传原始 uri, 不重复解析(避免三端口径漂移)。
 */
import { AbilityConstant, common, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { K_LAUNCH_URL, K_PENDING_DEEPLINK } from '../common/Consts';

/** 该 uri 是否为本应用的深链(自定义 scheme 或官方 https 邀请/临时链接) */
function isDeepLink(uri: string): boolean {
  if (!uri || uri.length === 0) {
    return false;
  }
  if (uri.startsWith('lmhchat://')) {
    return true;
  }
  if (uri.startsWith('https://chat.linminhao.top/i/') || uri.startsWith('https://chat.linminhao.top/t/')) {
    return true;
  }
  if (uri.startsWith('https://linminhao.top/i/') || uri.startsWith('https://linminhao.top/t/')) {
    return true;
  }
  return false;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // AppStorage 初始化(Index 页与桥都会读; 冷启动深链在此定型)
    AppStorage.setOrCreate<string>(K_LAUNCH_URL, '');
    AppStorage.setOrCreate<string>(K_PENDING_DEEPLINK, '');

    // 冷启动: 系统把匹配的 uri 放进 want.uri; 是深链就记下, 供 App.getLaunchUrl 读
    const uri: string = want.uri ?? '';
    if (isDeepLink(uri)) {
      AppStorage.set(K_LAUNCH_URL, uri);
      console.info('LMH cold deeplink: ' + uri);
    }
    console.info('LMH onCreate, launchType=' + launchParam.launchType + ', deepLink=' + (uri ? 'yes' : 'no'));
  }

  /**
   * 热启动: 应用已在前台时用户点了深链(或在系统里选本 App 打开 https 链接),
   * 系统不重建 Ability 而回调 onNewWant。把 uri 写进 K_PENDING_DEEPLINK,
   * Index 页 onVisible/轮询后经桥转发 appUrlOpen 事件给前端。
   */
  onNewWant(want: Want): void {
    const uri: string = want.uri ?? '';
    if (isDeepLink(uri)) {
      AppStorage.set(K_LAUNCH_URL, uri); // 保持最新冷启动引用
      AppStorage.set(K_PENDING_DEEPLINK, uri);
      console.info('LMH hot deeplink: ' + uri);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index');
  }

  onForeground(): void {
    // 回前台: 若期间有热启动深链, Index 会消费 K_PENDING_DEEPLINK
  }
}
