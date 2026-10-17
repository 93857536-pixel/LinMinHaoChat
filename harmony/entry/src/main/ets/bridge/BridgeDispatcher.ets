/**
 * BridgeDispatcher — 鸿蒙壳的 Capacitor 兼容桥(原生侧)。
 *
 * 与 rawfile/bridge/lmh-bridge.js 逐字对齐(见 docs/bridge-protocol.md):
 *   JS → 原生 : window.lmhPost(b64)   b64 = btoa(encodeURIComponent(JSON {kind, ...}))
 *                 原生 buffer.from(b64,'base64') 解回 → JSON.parse → 按 kind 分发
 *   原生 → JS : webController.runJavaScript("window.lmhBridge.respond/emit/unregister(...)")
 *                 结果数据同样 base64(btoa 对称) 后拼进 runJavaScript 字符串, 避免转义地狱
 *
 * 分发面(与前端 registerPlugin 名对齐):
 *   VoiceRecorder: start / stop / cancel / isAvailable   → VoiceRecorder
 *   PnsAuth       : isAvailable / checkEnv / startLogin → PnsAuth(鸿蒙优雅降级,恒不可用)
 *   App           : getLaunchUrl / addListener(appUrlOpen) / removeListener → AppBridge
 */
import { buffer } from '@kit.ArkBuffer';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { K_LAUNCH_URL } from '../common/Consts';
import { VoiceRecorder } from '../voice/VoiceRecorder';
import { PnsAuth } from '../pns/PnsAuth';
import { AppBridge } from '../deeplink/AppBridge';

/** JS → 原生的一封消息(javaScriptProxy 收 b64 后解码而成) */
interface LmhCall {
  kind: string;      // 'call' | 'listen' | 'unlisten'
  plugin: string;
  method?: string;
  options?: Record<string, Object>;
  id?: string;
  event?: string;
  key?: string;
}

export class BridgeDispatcher {
  private context: common.UIAbilityContext;
  private webController: webview.WebviewController;
  private voice: VoiceRecorder;
  private pns: PnsAuth;
  private app: AppBridge;
  /** 事件监听表: key → (plugin, event)。供热启动深链 appUrlOpen 时回投 JS */
  private eventSubs: Map<string, { plugin: string; event: string }> = new Map();

  constructor(context: common.UIAbilityContext, webController: webview.WebviewController) {
    this.context = context;
    this.webController = webController;
    this.voice = new VoiceRecorder(context);
    this.pns = new PnsAuth();
    this.app = new AppBridge(context);
  }

  /**
   * javaScriptProxy 暴露给 JS 的唯一入口: window.lmhPost(b64)。
   * b64 = btoa(encodeURIComponent(JSON.stringify({kind,...})))
   */
  onJsPost(b64: string): void {
    // base64 契约(与 JS 侧 btoa(unescape(encodeURIComponent(json))) 逐字对称):
    // b64 = JSON 字符串的 UTF-8 字节 的 base64。这里 buffer.from(b64,'base64').toString('utf-8')
    // 还原出的就是原 JSON 字符串, 无需再 percent-decode。
    let raw: string;
    try {
      raw = buffer.from(b64, 'base64').toString('utf-8');
    } catch (e) {
      console.warn('LMH bridge bad b64: ' + JSON.stringify(e));
      return;
    }
    let msg: LmhCall;
    try {
      msg = JSON.parse(raw) as LmhCall;
    } catch (e) {
      console.warn('LMH bridge parse fail: ' + raw.slice(0, 120));
      return;
    }
    this.dispatch(msg);
  }

  private dispatch(msg: LmhCall): void {
    try {
      switch (msg.kind) {
        case 'call':
          this.handleCall(msg.plugin, msg.method || '', msg.options || {} as Record<string, Object>, msg.id);
          break;
        case 'listen':
          if (msg.key && msg.event) {
            this.eventSubs.set(msg.key, { plugin: msg.plugin || 'App', event: msg.event });
            // 首订阅 appUrlOpen: 立即把冷启动深链(AppStorage K_LAUNCH_URL)投给 JS
            if (msg.event === 'appUrlOpen') {
              const launchUrl: string = AppStorage.get<string>(K_LAUNCH_URL) ?? '';
              if (launchUrl.length > 0) {
                this.emitEvent(msg.plugin || 'App', msg.event, msg.key, { url: launchUrl });
              }
            }
          }
          break;
        case 'unlisten':
          if (msg.key) {
            this.eventSubs.delete(msg.key);
            this.runJs(`window.lmhBridge.unregister(${this.jsStr(msg.key)});`);
          }
          break;
        default:
          break;
      }
    } catch (e) {
      const err = e as BusinessError;
      if (msg.id) {
        this.respond(msg.id, false, { error: `bridge dispatch failed: ${err.message || String(e)}` });
      }
    }
  }

  private handleCall(plugin: string, method: string, options: Record<string, Object>, id?: string): void {
    switch (plugin) {
      case 'VoiceRecorder':
        this.voice.dispatch(method, options, (ok, payload, errMsg) => {
          if (id) {
            if (ok && errMsg === undefined) this.respond(id, true, payload);
            else this.respond(id, ok, errMsg ? { error: errMsg } : (payload || {}));
          }
        });
        break;
      case 'PnsAuth':
        this.pns.dispatch(method, options, (ok, payload, errMsg) => {
          if (id) {
            if (ok && errMsg === undefined) this.respond(id, true, payload);
            else this.respond(id, ok, errMsg ? { error: errMsg } : (payload || {}));
          }
        });
        break;
      case 'App':
        this.app.dispatch(method, options, (ok, payload, errMsg) => {
          if (id) {
            if (ok && errMsg === undefined) this.respond(id, true, payload);
            else this.respond(id, ok, errMsg ? { error: errMsg } : (payload || {}));
          }
        });
        break;
      default:
        if (id) this.respond(id, false, { error: `unknown plugin ${plugin}` });
        break;
    }
  }

  /** 热启动深链: EntryAbility/页面把新 want.uri 写进 K_LAUNCH_URL 后调这里, 逐个已订阅 key 投 appUrlOpen */
  onDeepLink(uri: string): void {
    this.eventSubs.forEach((v, k) => {
      if (v.event === 'appUrlOpen') {
        this.emitEvent(v.plugin, v.event, k, { url: uri });
      }
    });
  }

  /** 向指定 key 回投事件(原生 runJavaScript) */
  emitEvent(plugin: string, event: string, key: string, data: Record<string, Object>): void {
    if (!key || key === '') return;
    const b64 = this.b64Json(data);
    this.runJs(`window.lmhBridge.emit(${this.jsStr(plugin)}, ${this.jsStr(event)}, ${this.jsStr(key)}, ${this.jsStr(b64)});`);
  }

  /**
   * 大 payload(语音 stop 的整段 base64)回传:与 Android Capacitor 生产实现同款——
   * 直接把完整结果 {base64, mime, durationMs} 经 respond 一次投回 JS(Chromium V8 对几百 KB
   * 字符串参数无硬限制)。不做分块,保持与 Android 口径一致、降低出错面。
   */
  /** 原生 → JS 回投一次 promise 结果 */
  private respond(id: string, ok: boolean, payload: Record<string, Object>): void {
    const b64 = this.b64Json(payload || {});
    this.runJs(`window.lmhBridge.respond(${this.jsStr(id)}, ${ok ? 'true' : 'false'}, ${this.jsStr(b64)});`);
  }

  private runJs(code: string): void {
    try {
      this.webController.runJavaScript(code, (err: BusinessError, ret: webview.JSInterface): void => {
        if (err) console.warn('LMH runJS: ' + err.message);
      });
    } catch (e) {
      const err = e as BusinessError;
      console.warn('LMH runJS sync: ' + (err.message || String(e)));
    }
  }

  /**
   * payload → b64(与 JS 侧 btoa(unescape(encodeURIComponent(json))) 逐字对称:
   * 两侧都把 JSON 编成「UTF-8 字节的 base64」。中文错误信息不会破坏 base64/JSON。 */
  private b64Json(obj: Record<string, Object>): string {
    const json = JSON.stringify(obj);
    return buffer.from(json, 'utf-8').toString('base64');
  }

  /** 把字符串安全地拼进 runJavaScript 的 JS 单引号字面量(先转义反斜杠, 再单引号/换行) */
  private jsStr(s: string): string {
    let t = String(s);
    t = t.replace(/\\/g, '\\\\'); // \  → \\
    t = t.replace(/'/g, "\\'");   // '  → \'
    t = t.replace(/\n/g, '\\n');  // 换行 → 字面 \n
    t = t.replace(/\r/g, '');
    return "'" + t + "'";
  }
}
