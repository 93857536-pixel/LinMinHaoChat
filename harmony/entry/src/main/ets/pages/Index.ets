/**
 * Index — LinMinHaoChat HarmonyOS 主页面(ArkWeb 壳)。
 *
 * 设计(见 docs/bridge-protocol.md):
 *   ArkWeb 直接加载生产站点 https://chat.linminhao.top/ —— 同源 /api /ws 不触发 CORS,
 *   https 安全上下文里 Web Crypto(Ed25519/ECDH-P256/HKDF/PBKDF2/AES-GCM)原生可用,
 *   分享链接 location.origin 天然正确。前端(与 Android 同一套 React)注入 Capacitor 兼容 shim 后
 *   isNativeShell()=true, 自动切到 mobile/MobileApp(四 Tab: 聊天/通讯录/发现/我的)。
 *
 * 桥接(ArkWeb ↔ 原生, 全程 base64):
 *   - javaScriptOnDocumentStart: 给 event.javaScriptCode 赋值 → 文档解析前注入 rawfile/bridge/lmh-bridge.js
 *   - javaScriptProxy 暴露 window.lmh.lmhPost(b64) → BridgeDispatcher.onJsPost(主通道)
 *   - onPromptDialog 兜底: '__LMH__' 前缀的 prompt(文本在 e.message)也走 onJsPost
 *   - 原生结果经 webController.runJavaScript("window.lmhBridge.respond/emit(...)") 回投
 *
 * 深链:
 *   冷启动 — EntryAbility.onCreate 把 want.uri 写进 AppStorage(K_LAUNCH_URL),
 *            前端 App.getLaunchUrl() 经桥读原生 AppStorage 拿到
 *   热启动 — EntryAbility.onNewWant 写 K_PENDING_DEEPLINK, 本页 AppStorage.on 监听 →
 *            dispatcher.onDeepLink(uri) → 逐 key emit appUrlOpen → 前端 parseDeepLink 推路由
 *
 * ⚠️ SDK 实测锚点: ArkWeb 各 hook 的精确签名(event 字段、javaScriptProxy 嵌套形态)随 API 版本
 *   略有差异, 以本机安装的 HarmonyOS SDK(API 12)编译结果为准。下方按官方 @kit.ArkWeb 标准范式
 *   书写; 保守处理: 不做 URL 白名单拦截(setWebViewRestriction 签名随 API 有差异, 避免编译风险,
 *   见 docs/bridge-protocol.md §6 加固注记)。
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { SITE_HOME, K_PENDING_DEEPLINK } from '../common/Consts';
import { BridgeDispatcher } from '../bridge/BridgeDispatcher';

/** 从 rawfile 同步读桥 JS(供 javaScriptOnDocumentStart 注入) */
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
  /** 深链 AppStorage 监听句柄(卸载时注销, 防泄漏) */
  private appStorageSubId: number = 0;

  aboutToAppear(): void {
    // 热启动转发: K_PENDING_DEEPLINK 变化(EntryAbility.onNewWant 写入)→ dispatcher.onDeepLink
    // → 逐个已订阅 appUrlOpen 的 key 投事件 → 前端 parseDeepLink 推路由。消费后清掉防重复。
    this.appStorageSubId = AppStorage.on('change', (key: string, value: Object) => {
      if (key === K_PENDING_DEEPLINK && value) {
        const uri: string = String(value);
        if (uri.length > 0) {
          this.dispatcher.onDeepLink(uri);
          AppStorage.set<string>(K_PENDING_DEEPLINK, '');
        }
      }
    });
    console.info('LMH Index aboutToAppear, bridgeJs=' + (this.bridgeJs.length > 0 ? 'loaded' : 'EMPTY'));
  }

  aboutToDisappear(): void {
    if (this.appStorageSubId !== 0) {
      AppStorage.off('change', this.appStorageSubId);
      this.appStorageSubId = 0;
    }
  }

  build() {
    Column() {
      Web({ src: SITE_HOME, webController: this.webController })
        .jsAccess(true)
        .javaScriptAccess(true)
        .domStorageAccess(true)      // 允许 localStorage(登录态)与 IndexedDB(E2EE 密钥)
        .fileAccess(false)
        .zoomAccess(false)
        .fileSelect(false)
        // ① 文档解析前注入 Capacitor 兼容桥(必须在 @capacitor/core 求值前执行)。
        //    标准用法: 给 event.javaScriptCode 赋值(ArkWeb 自动在页面脚本前执行), 无需再 runJavaScript。
        .javaScriptOnDocumentStart((e: webview.JavascriptExtensionEvent): void => {
          if (this.bridgeJs.length > 0) {
            e.javaScriptCode = this.bridgeJs;
          }
        })
        // ② 暴露 window.lmh.lmhPost(b64) → 原生分发(主通道)。
        //    ArkWeb 按 proxy 对象结构挂全局: 嵌套 { lmh:{lmhPost} } → JS 端 window.lmh.lmhPost(...)。
        //    JS 侧 nativePost 已三重兼容(window.lmh.lmhPost / window.lmhPost / prompt),
        //    故无论 SDK 最终挂哪种形态都能通。
        .javaScriptProxy({
          proxy: {
            lmh: {
              lmhPost: (b64: string): void => {
                this.dispatcher.onJsPost(b64);
              }
            }
          },
          controller: this.webController,
          methodList: ['lmhPost'],
          isInject: true
        })
        // ③ prompt 兜底通道: JS 侧在 javaScriptProxy 不可用时走 prompt('__LMH__'+b64)。
        //    prompt 文本在 e.message; 返回 true = 拦截(不显示系统弹窗)。
        .onPromptDialog((e: webview.PromptDialogData): boolean => {
          const m: string = e.message || '';
          if (m.startsWith('__LMH__')) {
            this.dispatcher.onJsPost(m.substring(7));
            return true;
          }
          return false;
        })
        // ④ 日志与错误上报(不做 URL 白名单拦截, 理由见文件头注记)
        .onPageBegin((e: webview.PageEvent): void => {
          console.info('LMH onPageBegin ' + e.url);
        })
        .onPageEnd((e: webview.PageEvent): void => {
          console.info('LMH onPageEnd ' + e.url);
        })
        .onErrorReceive((e: webview.ErrorEvent): void => {
          console.warn('LMH web error code=' + e.error.getErrorCode() + ' ' + e.error.getErrorMessage());
        })
        .onConsole((e: webview.WebConsole): boolean => {
          console.info('LMH web console: ' + e.message.getMessage());
          return false;
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
