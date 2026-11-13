/**
 * BridgeDispatcher — 鸿蒙壳的 Capacitor 兼容桥(原生侧)。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { K_LAUNCH_URL } from '../common/Consts';
import { VoiceRecorder, VoiceHandler } from '../voice/VoiceRecorder';
import { PnsAuth, PnsHandler } from '../pns/PnsAuth';
import { AppBridge, AppHandler } from '../deeplink/AppBridge';

interface LmhCall {
  kind: string;
  plugin: string;
  method?: string;
  options?: Record<string, Object>;
  id?: string;
  event?: string;
  key?: string;
}

interface LmhEventSub {
  plugin: string;
  event: string;
}

interface VoicePayload {
  base64?: string;
  mime?: string;
  durationMs?: number;
  available?: boolean;
}

interface AppPayload {
  url?: string;
  isActive?: boolean;
  name?: string;
  buildId?: string;
  version?: string;
}

interface PnsPayload {
  available?: boolean;
  error?: string;
}

function makeResult(error: string): Record<string, Object> {
  const obj: Record<string, Object> = new Object() as Record<string, Object>;
  obj['error'] = error;
  return obj;
}

function makeEventPayload(url: string): Record<string, Object> {
  const obj: Record<string, Object> = new Object() as Record<string, Object>;
  obj['url'] = url;
  return obj;
}

const base64Helper = new util.Base64Helper();

export class BridgeDispatcher {
  context: common.UIAbilityContext;
  webController: webview.WebviewController;
  voice: VoiceRecorder;
  pns: PnsAuth;
  app: AppBridge;
  eventSubs: Map<string, LmhEventSub> = new Map();

  constructor(context: common.UIAbilityContext, webController: webview.WebviewController) {
    this.context = context;
    this.webController = webController;
    this.voice = new VoiceRecorder(context);
    this.pns = new PnsAuth();
    this.app = new AppBridge(context);
  }

  onJsPost(b64: string): void {
    let raw: string;
    try {
      const bytes = base64Helper.decodeSync(b64);
      raw = new util.TextDecoder('utf-8').decode(bytes);
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
          this.handleCall(msg.plugin, msg.method || '', msg.options as Record<string, Object>, msg.id);
          break;
        case 'listen':
          if (msg.key && msg.event) {
            const sub: LmhEventSub = { plugin: msg.plugin || 'App', event: msg.event };
            this.eventSubs.set(msg.key, sub);
            if (msg.event === 'appUrlOpen') {
              const launchUrl: string = AppStorage.get<string>(K_LAUNCH_URL) ?? '';
              if (launchUrl.length > 0) {
                const eventPayload: Record<string, Object> = makeEventPayload(launchUrl);
                this.emitEvent(msg.plugin || 'App', msg.event, msg.key, eventPayload);
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
        const failPayload: Record<string, Object> = makeResult(`bridge dispatch failed: ${err.message || e.toString()}`);
        this.respond(msg.id, false, failPayload);
      }
    }
  }

  private handleCall(plugin: string, method: string, options: Record<string, Object>, id?: string): void {
    const doRespond = (ok: boolean, payload: Record<string, Object>, errMsg?: string): void => {
      if (id) {
        if (ok && errMsg === undefined) {
          this.respond(id, true, payload);
        } else {
          let responsePayload: Record<string, Object>;
          if (errMsg !== undefined) {
            responsePayload = makeResult(errMsg);
          } else {
            responsePayload = payload;
          }
          this.respond(id, ok, responsePayload);
        }
      }
    };

    switch (plugin) {
      case 'VoiceRecorder':
        this.voice.dispatch(method, options, new VoiceHandler((ok, payload, errMsg) => doRespond(ok, payload as Record<string, Object>, errMsg)));
        break;
      case 'PnsAuth':
        this.pns.dispatch(method, options, new PnsHandler((ok, payload, errMsg) => doRespond(ok, payload as Record<string, Object>, errMsg)));
        break;
      case 'App':
        this.app.dispatch(method, options, new AppHandler((ok, payload, errMsg) => doRespond(ok, payload as Record<string, Object>, errMsg)));
        break;
      default:
        if (id) {
          const errPayload: Record<string, Object> = makeResult(`unknown plugin ${plugin}`);
          this.respond(id, false, errPayload);
        }
        break;
    }
  }

  onDeepLink(uri: string): void {
    this.eventSubs.forEach((v: LmhEventSub, k: string) => {
      if (v.event === 'appUrlOpen') {
        const linkPayload: Record<string, Object> = makeEventPayload(uri);
        this.emitEvent(v.plugin, v.event, k, linkPayload);
      }
    });
  }

  emitEvent(plugin: string, event: string, key: string, data: Record<string, Object>): void {
    if (!key || key === '') return;
    const b64 = this.b64Json(data);
    this.runJs(`window.lmhBridge.emit(${this.jsStr(plugin)}, ${this.jsStr(event)}, ${this.jsStr(key)}, ${this.jsStr(b64)});`);
  }

  private respond(id: string, ok: boolean, payload: Record<string, Object>): void {
    const b64 = this.b64Json(payload);
    this.runJs(`window.lmhBridge.respond(${this.jsStr(id)}, ${ok ? 'true' : 'false'}, ${this.jsStr(b64)});`);
  }

  private runJs(code: string): void {
    try {
      this.webController.runJavaScript(code);
    } catch (e) {
      const err = e as BusinessError;
      console.warn('LMH runJS sync: ' + (err.message || e.toString()));
    }
  }

  private b64Json(obj: Record<string, Object>): string {
    const json = JSON.stringify(obj);
    const bytes = new util.TextEncoder().encode(json);
    return base64Helper.encodeToStringSync(bytes);
  }

  private jsStr(s: string): string {
    let t = String(s);
    t = t.replace(/\\/g, '\\\\');
    t = t.replace(/'/g, "\\'");
    t = t.replace(/\n/g, '\\n');
    t = t.replace(/\r/g, '');
    return "'" + t + "'";
  }
}
