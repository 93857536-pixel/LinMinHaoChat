# LinMinHaoChat HarmonyOS — 鸿蒙壳 ↔ Web 桥接协议规范

> 版本 v1.0 · 2026-10-17 · 主会话维护(业务文件照此对齐,勿各自发明协议)

## 0. 架构总览

鸿蒙版 = **ArkTS(Stage 模型) 壳 + ArkWeb 容器 + 注入的 Capacitor 兼容 JS 桥**。

- ArkWeb **直接加载生产站点 `https://chat.linminhao.top/`**(同源: `/api` `/ws` 同域、
  https 安全上下文 → Web Crypto 可用、分享链接 `location.origin` 天然正确、**零 CORS 死结**)。
  前端是 `web/` 同一套 React(与 Android/iOS 功能 100% 对齐),ArkWeb 内核为 Chromium M114,
  Web Crypto(Ed25519/ECDH-P256/HKDF/PBKDF2/AES-GCM/SHA-256)、IndexedDB、wss、btoa/atob
  全部原生内置 → **E2EE 纯 Web 直跑,无需原生 crypto 桥**。
- ArkWeb 通过 `javaScriptOnDocumentStart` 注入一套 **Capacitor 兼容 shim**,使
  `globalThis.Capacitor.isNativePlatform() === true` → 前端 `main.tsx` 自动切到
  `mobile/MobileApp`(四 Tab 壳:聊天/通讯录/发现/我的),并注入 `__LMH_API_BASE__`/`__LMH_WS_BASE__`。
- JS↔原生走 `javaScriptProxy`(JS→原生同步调用)+ `runJavaScript`(原生→JS 推送结果/事件)。

## 1. 全局对象约定

| 对象 | 由谁建 | 作用 |
|---|---|---|
| `globalThis.Capacitor` | JS shim(javaScriptOnDocumentStart) | 使前端 `registerPlugin`/`isNativePlatform` 走原生路径 |
| `globalThis.CapacitorCustomPlatform` | JS shim | `{name:'harmony', getPlatform, isNativePlatform, isPluginAvailable, getPluginHeader}` |
| `globalThis.CapacitorPlatforms` | JS shim | `{currentPlatform, platforms:Map, addPlatform, setPlatform}` |
| `globalThis.Capacitor.PluginHeaders` | JS shim | 原生插件元数据(methods + rtype),让 `registerPlugin` 路由到 `nativePromise/nativeCallback` |
| `globalThis.LMH` | JS shim | 桥分发器:`call / nativeResolve / emitEvent / unregisterEvent` |
| `globalThis.LMHNative` | ArkTS(javaScriptProxy) | 原生能力入口:`call(plugin, method, optionsJson, cbId, isCallback)` |

## 2. 调用协议(JS → 原生 → JS)

### 2.1 Promise 类方法(rtype='promise')
```
JS:  p = LMH.call(plugin, method, options, false)
     cbId = ++seq; pending[cbId] = {resolve, reject}
     LMHNative.call(plugin, method, JSON.stringify(options), String(cbId), '0')   // javaScriptProxy 同步调
原生: 执行能力(异步); 完成后 →
     webviewController.runJavaScript(`LMH.nativeResolve(${cbId}, ${ok}, ${JSON.stringify(payloadJson)})`)
JS:  LMH.nativeResolve(cbId, ok, payloadJson) → ok? resolve(parsed): reject(Error(payload.error))
```
- 超时 30s(`startLogin` 这种用户交互类放宽到 120s,由原生侧控制语义)。
- `payloadJson` 为方法返回对象的 JSON.stringify;失败时 `ok=false` 且 payload 为 `{error: 中文可读原因}`。

### 2.2 事件类方法(rtype='callback',即 addListener/removeListener)
```
JS:  LMH.call(plugin, 'addListener', {eventName}, true, listener)
     cbId = ++seq; pending[cbId] = {isCallback:true, listener, subId:null}
     LMHNative.call(plugin, 'addListener', JSON.stringify({eventName}), String(cbId), '1')
原生: 注册监听; 生成 subId(=可用 cbId); 立即回执 →
     webviewController.runJavaScript(`LMH.nativeResolve(${cbId}, true, ${JSON.stringify({})}, ${subId})`)
JS:  首次 nativeResolve → pending[cbId].subId = subId; resolve(subId)(保留 entry,不删除,后续事件复用)
原生: 事件发生(如 appUrlOpen) →
     webviewController.runJavaScript(`LMH.emitEvent(${JSON.stringify(plugin)}, ${JSON.stringify(event)}, ${JSON.stringify(data)}, ${subId})`)
JS:  LMH.emitEvent(plugin, event, dataJson, subId) → 调 pending[subId].listener({type:event, ...data})
JS:  removeListener → LMH.call(plugin,'removeListener',{eventName, callbackId:subId}, true)
     原生注销 + LMH.unregisterEvent(subId)
```

## 3. 必须复刻的前端插件面(与 Android 逐字对齐)

| 插件 | 方法 | 返回 | 说明 |
|---|---|---|---|
| `VoiceRecorder` | `start()` | `{}` | 开始录 m4a(AAC in MP4) |
| | `stop()` | `{base64, mime:'audio/mp4', durationMs}` | 结束并回传 base64 音频 |
| | `cancel()` | `{}` | 丢弃 |
| | `isAvailable()` | `{available:true}` | 原生录音始终可用 |
| `PnsAuth` | `isAvailable()` | `{available:false}` | 鸿蒙暂无阿里云 PNS SDK → 降级(见 §5) |
| | `checkEnv()` | `{available:false, error:'HarmonyOS 暂不支持一键登录'}` | 前端据此隐藏一键登录按钮 |
| | `startLogin()` | reject `{error:'当前系统暂不支持一键登录,请使用验证码'}` | 前端已有优雅降级路径 |
| `App` | `getLaunchUrl()` | `{url: 冷启动深链或 ''}` | 对应前端 `CapApp.getLaunchUrl` |
| | `addListener('appUrlOpen')` | 事件 `{url}` | 热启动深链 → `LMH.emitEvent('App','appUrlOpen',{url},subId)` |

> 前端 `VoiceRecorder/PnsAuth/@capacitor/app` 的 `registerPlugin` 名与接口**零改动**,
> 只需 `Capacitor.isNativePlatform()===true` + `PluginHeaders` 正确即原样跑起来。

## 4. 深链规则(与 web/src/mobile/deeplink.ts 对齐)
- `lmhchat://invite/<id>#k=…`、`lmhchat://i/<id>`、`lmhchat://t/<id>` → 自定义 scheme(module.json5 skills.uri)
- `https://chat.linminhao.top/i/<id>#k=…`、`…/t/<id>`、`https://linminhao.top/t/<id>` → 官方 https 链接
- 冷启动: EntryAbility 拿启动 want.uri → 存 launchUrl → `App.getLaunchUrl` 返回
- 热启动: 应用已在前台再点链接 → `LMH.emitEvent('App','appUrlOpen',{url: rawUrl})` → 前端 `parseDeepLink` 推路由
- ⚠️ 必须保留 fragment(`#k=密钥`)与 query(`?account=` `?roomCode=`),前端解析依赖它

## 5. 一键登录(PNS)策略
- 现状: 阿里云号码认证**无 HarmonyOS NEXT 官方 SDK**;服务端 `/api/pns/phone-check` 走阿里云
  GetMobile(平台无关,spToken 换号)。鸿蒙端暂无合规 spToken 来源。
- v1 决策: **优雅降级** —— `PnsAuth` 全部返回「不可用」,前端 Login 页隐藏「本机号码一键登录」按钮,
  保留邮箱/手机验证码登录(功能闭环)。与 iOS/Android 相比**仅少一键登录入口**,其余 100% 一致。
- 升级路径(留好接口): 待阿里云出鸿蒙 PNS SDK,或接个推(JPush)一键认证 HarmonyOS SDK + 服务端新增
  对应换号端点,替换 `PnsAuth.ets` 的降级桩即可,桥协议不变。

## 6. 安全约束
- ArkWeb 用 `setWebViewRestriction`(URL filter)锁定仅 `*.linminhao.top` + `lmhchat:`,防跳转劫持。
- E2EE 私钥只存设备侧 IndexedDB(随 WebView 数据),绝不上行;服务器只收公钥(与 Android/iOS 同口径)。
- 不在 WebView 里存任何明文凭证;登录态走前端 localStorage(WebView 分区数据)。

## 7. 产物
- 工程根 `harmony/`,hvigor 构建,产出 `entry/build/.../app.hap`。
- 本机无 DevEco: 交付「完整 DevEco 工程 + CLI 构建脚本 + 签名指引 + 一键登录降级说明」,
  真 .hap 需登录华为账号装 Command Line Tools / DevEco 后 `hvigorw assembleHap` 出包。
