# LinMinHao Chat · HarmonyOS(鸿蒙)版

端到端加密聊天应用的**鸿蒙(HarmonyOS NEXT)原生壳**。与 Android、iOS 版功能对齐：
聊天 / 通讯录 / 发现 / 我的 四 Tab，E2EE（ECDH P-256 + AES-256-GCM）、临时聊天、邀请聊天、
转发、收藏、语音消息、深链、登录。

## 架构：为什么这么设计

鸿蒙版**不重写 35 个前端文件**，而是复用 Android/iOS 同一套 React 前端（`web/`），
用一个 **ArkTS(Stage 模型) 原生壳 + ArkWeb 容器** 把它跑起来——和 Android 的 Capacitor
方案完全对齐，从而**功能面由构造保证 100% 对齐**，避免 E2EE/聊天逻辑三端各自复刻引入不一致。

关键决策（均有依据）：

| 决策 | 依据 |
|---|---|
| ArkWeb **直接加载生产站点 `https://chat.linminhao.top/`**，不把 `web/dist` 打进 hap | 生产 nginx 把 `/api`、`/ws` 同源反代到后端，站点源即服务端 `CORS_ORIGIN`。同源加载**零 CORS 死结**；https 安全上下文里 **Web Crypto 可用**（E2EE 靠它）；分享链接 `location.origin` 天然正确。本地 dist 跨域 fetch 生产域名会被严格 CORS 403 拒。 |
| 注入 **Capacitor 兼容 JS 桥**（预置 `window.Capacitor*`，`javaScriptProxy` + `runJavaScript` 双向） | 前端 `main.tsx` 的 `isNativeShell()` 检测 `Capacitor.isNativePlatform()`。注入后返回 `true` → 自动切到 `mobile/MobileApp`（四 Tab 壳）并注入 API/WS 绝对基址。`VoiceRecorder`/`PnsAuth`/`@capacitor/app`（深链）**零改动**原样跑。 |
| 原生桥补三块：语音、深链、隐私 | 语音必须 m4a/AAC（iOS 端 AVAudioPlayer 播放、服务端白名单不收 webm），WebView 的 MediaRecorder 给不了，故用 ArkTS `@ohos.multimedia.media` AVRecorder 直出 m4a。深链用 ArkWeb `onNewWant`/`javaScriptOnDocumentStart`。 |

### 调研结论（2026-10-17，三个并行子代理）
- **ArkWeb 内核 = Chromium M114（V8）**：Web Crypto（Ed25519/ECDH P-256/HKDF/PBKDF2/AES-GCM/SHA-256）、
  IndexedDB、`wss`、`btoa/atob`、`TextEncoder` **全部原生内置** → E2EE **纯 Web 直跑，无需原生 crypto 桥**。
- **阿里云号码认证无 HarmonyOS NEXT 官方 SDK**（服务端 `/api/pns/phone-check` 是阿里云 GetMobile 专属）
  → 鸿蒙端**一键登录优雅降级**：`PnsAuth.isAvailable()=false`，前端 Login 页自动隐藏「本机号码一键登录」按钮，
  保留邮箱/手机**验证码登录**（功能闭环）。个推/极光有鸿蒙一键认证 SDK，但服务端换号端点需另配，v1 暂不引入。
- **macOS 可 CLI 出 .hap**，但需登录华为账号装 Command Line Tools + 本地/调试签名（见下）。

## 目录结构
```
harmony/
├─ AppScope/                 应用级配置(bundleName/version) + 资源
├─ entry/                    入口模块
│  ├─ src/main/ets/
│  │  ├─ entryability/EntryAbility.ets   UIAbility: 深链冷/热启动 → AppStorage
│  │  ├─ pages/Index.ets                 ArkWeb 壳(接桥/白名单/深链转发)
│  │  ├─ bridge/BridgeDispatcher.ets     JS↔原生 桥分发(javaScriptProxy + runJavaScript)
│  │  ├─ voice/VoiceRecorder.ets         AVRecorder→m4a(AAC) 语音桥
│  │  ├─ pns/PnsAuth.ets                 一键登录(鸿蒙降级桩: 恒不可用, 前端隐藏按钮)
│  │  ├─ deeplink/AppBridge.ets          @capacitor/app 兼容(深链 getLaunchUrl/appUrlOpen)
│  │  └─ common/Consts.ets               域名/scheme/rawfile 路径等跨文件契约
│  └─ src/main/resources/rawfile/bridge/lmh-bridge.js   注入 ArkWeb 的 Capacitor 兼容 JS 桥
├─ hvigorw / build.sh / build-profile.json5 / oh-package.json5   构建
└─ docs/bridge-protocol.md   JS↔原生桥接协议规范(所有文件照此对齐)
```

## 构建 .hap（macOS）

> ⚠️ 本机当前**未装** DevEco Studio / HarmonyOS SDK。出包需先装华为 Command Line Tools
> （登录开发者账号，免费）+ JDK 17 + node 20。一次性步骤：

1. 登录 <https://developer.huawei.com/consumer/cn/download/>，下载 **macOS (arm64) HarmonyOS Command Line Tools**
   （选与 API 12+ 匹配的版本，5.x/6.x 系列），解压到 `~/command-line-tools`。
2. 确认 JDK 17（`/usr/libexec/java_home -v 17`）与 node ≥ 18。
3. 首次构建在 **DevEco Studio** 里导入本目录，做一次「本地自动签名」（生成调试证书 + `.pb` 签名 profile），
   或自备调试/发布证书填入 `build-profile.json5` 的 `signingConfigs`。
4. 然后一键构建：
   ```bash
   cd harmony
   export OHOS_HOME=~/command-line-tools
   export PATH="$OHOS_HOME/bin:$OHOS_HOME/toolchains:$PATH"
   ./build.sh            # debug hap(默认)
   ./build.sh release     # release hap
   ```
   产物 `entry/build/outputs/.../entry-default-*.hap`，并复制到 `~/Desktop/LinMinHaoChat-harmony-1.9.16-*.hap`。

**签名说明**：未配置证书时 `assembleHap` 会报 `no signing profile`。调试自测可用「本地自动签名」
生成的调试 profile（`buildMode=debug` + `debuggable=true` 免签即可出 debug hap，部分工具链要求至少一个
调试证书）；上架/正式分发布需 DevEco「应用管理」申请发布证书 + 打包 profile。

## 安装与运行
- hap 双击/`hdc install` 到鸿蒙真机（纯 Web 壳，需联网——ArkWeb 加载生产站点；离线不可用）。
- 首次启动进登录页：邮箱/手机验证码登录。一键登录按钮在鸿蒙端**不显示**（降级）。
- 语音消息：长按录音 → m4a 上传（需麦克风权限，首次会弹授权）。

## 一键登录降级（PNS）
鸿蒙端暂无阿里云号码认证 SDK，故 v1 隐藏「本机号码一键登录」入口，仅保留验证码登录。
升级路径见 `docs/bridge-protocol.md` §5（接个推/极光鸿蒙 SDK + 服务端新增对应换号端点，替换
`ets/pns/PnsAuth.ets` 降级桩即可，桥协议不变）。

## 安全
- ArkWeb `onLoadIntercept` 白名单锁 `*.linminhao.top` + `lmhchat:`，防跳转劫持。
- E2EE 私钥只存设备侧 IndexedDB（ArkWeb 分区数据），绝不上行；服务器只收公钥（与 Android/iOS 同口径）。

## 版本
1.9.16 · 与 Android/iOS 对齐（鸿蒙为一端壳，功能面继承共享前端）。
