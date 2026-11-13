/**
 * Index — LinMinHaoChat HarmonyOS 主页面(ArkWeb 壳)。
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { SITE_HOME } from '../common/Consts';
import { BridgeDispatcher } from '../bridge/BridgeDispatcher';

function loadBridgeJs(ctx: common.UIAbilityContext): string {
  try {
    const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('bridge/lmh-bridge.js');
    return new util.TextDecoder('utf-8').decode(bytes);
  } catch (e) {
    const err = e as BusinessError;
    console.error('LMH load bridge js fail: ' + (err.message || String(e)));
    return '';
  }
}

@Entry
@Component
struct Index {
  private webController: webview.WebviewController = new webview.WebviewController();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private bridgeJs: string = loadBridgeJs(this.context);
  private dispatcher: BridgeDispatcher = new BridgeDispatcher(this.context, this.webController);

  aboutToAppear(): void {
    console.info('LMH Index aboutToAppear, bridgeJs=' + (this.bridgeJs.length > 0 ? 'loaded' : 'EMPTY'));
  }

  build() {
    Column() {
      Web({ src: SITE_HOME, controller: this.webController })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .zoomAccess(false)
        .javaScriptOnDocumentStart([{ script: this.bridgeJs, scriptRules: [] }])
        .javaScriptProxy({
          object: {
            lmh: {
              lmhPost: (b64: string): void => {
                this.dispatcher.onJsPost(b64);
              }
            }
          },
          name: 'lmh',
          methodList: ['lmhPost'],
          controller: this.webController
        })
        .onPageBegin(() => {
          console.info('LMH onPageBegin');
        })
        .onPageEnd(() => {
          console.info('LMH onPageEnd');
        })
        .width('100%')
        .height('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }
}
