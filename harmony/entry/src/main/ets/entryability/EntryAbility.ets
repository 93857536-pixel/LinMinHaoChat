/**
 * EntryAbility — LinMinHaoChat HarmonyOS 入口(UIAbility, Stage 模型)。
 */
import { AbilityConstant, common, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { K_LAUNCH_URL, K_PENDING_DEEPLINK } from '../common/Consts';

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
    AppStorage.setOrCreate<string>(K_LAUNCH_URL, '');
    AppStorage.setOrCreate<string>(K_PENDING_DEEPLINK, '');

    const uri: string = want.uri ?? '';
    if (isDeepLink(uri)) {
      AppStorage.set(K_LAUNCH_URL, uri);
      console.info('LMH cold deeplink: ' + uri);
    }
    console.info('LMH onCreate, launchReason=' + launchParam.launchReason + ', deepLink=' + (uri ? 'yes' : 'no'));
  }

  onNewWant(want: Want): void {
    const uri: string = want.uri ?? '';
    if (isDeepLink(uri)) {
      AppStorage.set(K_LAUNCH_URL, uri);
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
