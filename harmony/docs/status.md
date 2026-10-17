# 鸿蒙版现状与待办 · 2026-10-17

## 三个后台子代理结论（全已完成）
1. ArkWeb = Chromium M114，Web Crypto（Ed25519/ECDH-P256/HKDF/PBKDF2/AES-GCM/SHA-256/IndexedDB/wss/btoa/atob）全部原生内置；Ed25519 在 M113 引入 / M114 临界 → **真机冒烟确认**，失败则回退 ECDSA-P256（本项目已用 P-256，安全）
2. 阿里云号码认证无 HarmonyOS NEXT SDK，个推/极光 token 平台锁定 → **优雅降级验证码登录**
3. macOS CLI 可出 .hap（需登录华为账号下 Command Line Tools + JDK17 + 本地签名）

## 工程已交付
- `harmony/` 30 文件 / ~1500 行：ArkTS(Stage) 壳 + ArkWeb + 注入 Capacitor 兼容桥
- 前端 `VoiceRecorder`/`PnsAuth`/`@capacitor/app` 零改动原样跑
- `docs/bridge-protocol.md` 协议全文 + `docs/verify-bridge.mjs` 离线对拍（9/9 通过）
- `build.sh` / `hvigorw` / README 含构建与签名指引

## 生产部署现状（待确认）
**发现 hash 不一致**：
- 生产 `https://chat.linminhao.top/assets/index-B1LzumBH.js`（224846B）
- 本地 `web/dist/assets/index-DoKEcdBE.js`（322KB）
- 两者均含 `linminhao.top`（CORS 配置）但本地产出更大、含移动端壳懒加载 chunk

**最可能原因**：线上 dist 是「加了移动端壳之前」的旧构建，没重新随 Android v1.9.16 一起部署。

## 建议的下一步（选一或都选）
(a) **重新部署 web/dist 到生产**（与 Android/iOS 同源，一劳永逸；也是让鸿蒙壳正确渲染移动 UI 的前置条件）
(b) **先提交 `harmony/` 到 git**（让鸿蒙工程进入版本控制）
(c) DevEco Studio 导入后 Build 一次，按报错修 ArkWeb/AVRecorder 字段（SDK 版本差异必报，易修）

## 注意事项
- 真 `.hap` 包必须在你登录华为账号的机器上跑 `./build.sh`（本机无鸿蒙工具链）
- ArkWeb `javaScriptProxy` / `onPromptDialog` / AVRecorder `outputFd` 的精确字段名按官方范式写，首次编译若有出入按报错改
- PNS 降级桩方向正确：前端 `pnsOk=false` 自动隐藏一键登录按钮
