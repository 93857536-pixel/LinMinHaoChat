/*
 * lmh-bridge.js — LinMinHaoChat HarmonyOS 壳的 Capacitor 兼容桥(JS 侧)。
 *
 * 由 ArkWeb `javaScriptOnDocumentStart` 在 @capacitor/core 求值**之前**注入(预置 window.Capacitor*),
 * 使前端已打包的 `registerPlugin('VoiceRecorder')` / `PnsAuth` / `@capacitor/app` **零改动**原样跑起来。
 *
 * 传输层(与 ets/bridge/BridgeDispatcher.ets 逐字对齐, 见 docs/bridge-protocol.md):
 *   JS → 原生 : 单一全局函数 window.lmhPost(b64)   [ArkWeb javaScriptProxy 暴露, prompt 兜底]
 *                 b64 = btoa(encodeURIComponent(JSON.stringify({kind, ...})))
 *                 kind: 'call'   → {plugin, method, options, id}
 *                       'listen' → {plugin, event, key}
 *                       'unlisten' → {plugin, event, key}
 *   原生 → JS : webController.runJavaScript("window.lmhBridge.respond(id, ok, b64)")
 *                  webController.runJavaScript("window.lmhBridge.emit(plugin, event, key, b64)")
 *                  webController.runJavaScript("window.lmhBridge.unregister(key)")
 *   全程 base64 传输, 避免引号/换行在 runJavaScript 字符串里转义出错(Chromium atob 直解)。
 *
 * 为什么 pre-seed window.Capacitor / CapacitorPlatforms / CapacitorCustomPlatform:
 *   前端 @capacitor/core 的 createCapacitor() 会 `win.Capacitor || {}` 复用本对象并补 registerPlugin/Plugins;
 *   CapacitorCustomPlatform={name:'harmony'} + isNativePlatform()=>true → 前端 main.tsx isNativeShell() 为真,
 *   自动切 mobile/MobileApp(四 Tab), 并注入 API/WS 绝对基址(加载生产同源站点, 零 CORS)。
 */
(function () {
  var win = (typeof globalThis !== 'undefined') ? globalThis
        : (typeof self !== 'undefined') ? self
        : (typeof window !== 'undefined') ? window
        : (typeof global !== 'undefined') ? global : {};

  /* ---------------- 原生 → JS 回投入口(原生经 runJavaScript 调这两个) ---------------- */
  var pending = new Map();    // id   → {resolve, reject}
  var listeners = new Map();  // key  → {plugin, event, handler}

  /* base64 编码契约(与 ets/bridge/BridgeDispatcher.ets 逐字对称):
   *   JS  编码: b64 = btoa(unescape(encodeURIComponent(json)))   ← UTF-8 字节的 base64
   *   JS  解码: json = new TextDecoder().decode(bytes(atob(b64)))
   *   原生 编码: buffer.from(json,'utf-8').toString('base64')
   *   原生 解码: buffer.from(b64,'base64').toString('utf-8')
   * 两侧都把 JSON 编成「UTF-8 字节的 base64」, 中文错误信息不会破坏 base64/JSON。 */
  function b64encode(jsonStr) { return btoa(unescape(encodeURIComponent(jsonStr))); }
  function b64decode(b64) {
    if (!b64) return {};
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    var text = (typeof TextDecoder !== 'undefined')
      ? new TextDecoder('utf-8').decode(bytes)
      : decodeURIComponent(escape(bin)); // 老内核兜底
    try { return JSON.parse(text); } catch (_) { return {}; }
  }

  win.lmhBridge = {
    respond: function (id, ok, b64) {
      var p = pending.get(String(id));
      if (!p) return;
      pending.delete(String(id));
      var data = b64decode(b64);
      if (ok) { p.resolve(data); }
      else { p.reject(new Error((data && typeof data.error === 'string') ? data.error : 'native error')); }
    },
    emit: function (plugin, event, key, b64) {
      var rec = listeners.get(String(key));
      if (!rec) return;
      var data = b64decode(b64);
      var payload = { type: event, plugin: plugin };
      if (data && typeof data === 'object') {
        for (var k in data) if (Object.prototype.hasOwnProperty.call(data, k)) payload[k] = data[k];
      }
      rec.handler(payload);
    },
    unregister: function (key) { listeners.delete(String(key)); }
  };

  /* ---------------- JS → 原生(经 javaScriptProxy 暴露的 window.lmhPost, prompt 兜底) ---------------- */
  var seq = 0;

  // b64encode 已在上方定义; 这里补一个把 JSON.stringify 直接走 b64encode 的便捷
  function jsonB64(obj) { return b64encode(JSON.stringify(obj)); }

  /* 原生通道: 主用 ArkWeb javaScriptProxy 暴露的 window.lmh.lmhPost(b64)(或扁平 window.lmhPost),
   * 兜底用 window.prompt('__LMH__'+b64) 经 onPromptDialog。三者任一可用即可。 */
  function nativePost(b64) {
    if (win.lmh && typeof win.lmh.lmhPost === 'function') { win.lmh.lmhPost(b64); return; }
    if (typeof win.lmhPost === 'function') { win.lmhPost(b64); return; }
    if (typeof win.prompt === 'function') { win.prompt('__LMH__' + b64); return; }
    throw new Error('no native channel (lmh.lmhPost / lmhPost / prompt 均不可用)');
  }

  function postToNative(msg) {
    var b64 = b64encode(JSON.stringify(msg));
    nativePost(b64);
  }

  function nativeCall(plugin, method, options) {
    return new Promise(function (resolve, reject) {
      var id = String(++seq);
      pending.set(id, { resolve: resolve, reject: reject });
      var timeoutMs = (method === 'startLogin') ? 120000 : 30000;
      var t = setTimeout(function () {
        if (pending.has(id)) { pending.delete(id); reject(new Error(plugin + '.' + method + ' 超时')); }
      }, timeoutMs);
      try {
        postToNative({ kind: 'call', plugin: plugin, method: method, options: options || {}, id: id });
      } catch (e) { clearTimeout(t); pending.delete(id); reject(e); }
    });
  }

  function addListener(plugin, event, handler) {
    var key = String(++seq);
    listeners.set(key, { plugin: plugin, event: event, handler: handler });
    var reg;
    try {
      reg = Promise.resolve(postToNative({ kind: 'listen', plugin: plugin, event: event, key: key }));
    } catch (e) { reg = Promise.reject(e); }
    return reg.then(function () {
      return {
        remove: function () {
          listeners.delete(key);
          try { postToNative({ kind: 'unlisten', plugin: plugin, event: event, key: key }); } catch (_) { /* ignore */ }
          return Promise.resolve();
        }
      };
    });
  }

  /* ---------------- 简化版 registerPlugin ----------------
   * 普通方法 → nativeCall(promise); addListener/removeListener → 事件注册。
   * 经 win.CapacitorPlatforms.currentPlatform.registerPlugin 注入 @capacitor/core。 */
  function registerPlugin(name) {
    var capPlugins = (win.Capacitor && win.Capacitor.Plugins) || {};
    if (capPlugins[name]) return capPlugins[name];
    var proxy = new Proxy({}, {
      get: function (_, prop) {
        if (typeof prop !== 'string') return undefined;
        if (prop === 'addListener') {
          return function (eventName, handler) { return addListener(name, eventName, handler); };
        }
        if (prop === 'removeListener') {
          return function (eventName, key) {
            listeners.delete(String(key));
            try { postToNative({ kind: 'unlisten', plugin: name, event: eventName, key: key }); } catch (_) { /* ignore */ }
            return Promise.resolve();
          };
        }
        return function (options) { return nativeCall(name, prop, options); };
      }
    });
    capPlugins[name] = proxy;
    if (win.Capacitor) win.Capacitor.Plugins = capPlugins;
    return proxy;
  }

  /* ---------------- 预置 Capacitor 全局 ---------------- */
  var cap = win.Capacitor || {};
  cap.Plugins = cap.Plugins || {};
  cap.registerPlugin = registerPlugin;
  cap.isNativePlatform = function () { return true; };
  cap.getPlatform = function () { return 'harmony'; };
  cap.isPluginAvailable = function () { return true; };
  cap.convertFileSrc = function (p) { return p; };
  cap.DEBUG = false;
  cap.isLoggingEnabled = false;
  cap.handleError = function (e) { win.console && win.console.error && win.console.error(e); };
  cap.Exception = function (m, c, d) { var e = new Error(m || ''); e.code = c || 'UNIMPLEMENTED'; e.data = d; return e; };

  win.Capacitor = cap;
  var curPlatform = {
    name: 'harmony',
    registerPlugin: registerPlugin,
    isNativePlatform: function () { return true; },
    getPlatform: function () { return 'harmony'; },
    isPluginAvailable: function () { return true; }
  };
  win.CapacitorPlatforms = {
    currentPlatform: curPlatform,
    platforms: new Map([['web', { name: 'web' }], ['harmony', curPlatform]]),
    addPlatform: function (n, p) { win.CapacitorPlatforms.platforms.set(n, p); },
    setPlatform: function (n) {
      if (win.CapacitorPlatforms.platforms.has(n)) { win.CapacitorPlatforms.currentPlatform = win.CapacitorPlatforms.platforms.get(n); }
    }
  };
  win.CapacitorCustomPlatform = { name: 'harmony', registerPlugin: registerPlugin };

  /* ---------------- 兜底 __LMH_API_BASE__ / __LMH_WS_BASE__ ----------------
   * ArkWeb 加载生产同源站点(https://chat.linminhao.top): 同源 /api /ws 直接通, E2EE 在 https
   * 安全上下文里跑, 分享链接 location.origin 天然正确。前端 main.tsx 还会再设一次绝对基址,
   * 这里兜底防打包时序差异让 api.ts/ws.ts 读到空串。 */
  try {
    var loc = win.location;
    if (loc && loc.protocol === 'https:' && /linminhao\.top$/.test(loc.hostname)) {
      if (!win.__LMH_API_BASE__) { win.__LMH_API_BASE__ = 'https://' + loc.host + '/api'; }
      if (!win.__LMH_WS_BASE__) { win.__LMH_WS_BASE__ = 'wss://' + loc.host; }
    }
  } catch (e) { /* ignore */ }
})();
