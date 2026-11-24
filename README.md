# LinMinHao Chat 🔐

**端到端加密(E2EE)聊天 · iOS / Android / HarmonyOS 三端原生客户端 · Web 为测试/兼容客户端**

> 📱 正式客户端:iOS 原生 App(SwiftUI + CryptoKit + Keychain)。Web 版保留为开发测试 / E2EE 协议测试 / 兼容性测试客户端:
> https://chat.linminhao.top(后端基础设施;Web 前端测试入口,2026-10-05 起从根域名迁移)

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Node](https://img.shields.io/badge/Node-22+-blue.svg)
![React](https://img.shields.io/badge/React-18-blue.svg)
![Swift](https://img.shields.io/badge/SwiftUI-iOS-blue.svg)
![TypeScript](https://img.shields.io/badge/TypeScript-5-blue.svg)
![HarmonyOS](https://img.shields.io/badge/HarmonyOS-NEXT-orange.svg)
![Android](https://img.shields.io/badge/Android-Capacitor-green.svg)

---

## ✨ 产品定位

**iOS 原生 App 是正式用户客户端,chat.linminhao.top 是后端基础设施(2026-10-05 从根域名迁到 chat 子域名)。**

```
iOS / Android / HarmonyOS 原生客户端(用户主要使用)
    ↓ HTTPS API / WSS(客户端自动连接,用户无需接触浏览器)
chat.linminhao.top 后端(Node.js + SQLite + 文件系统密文归档)
    ↓
E2EE 密文存储 —— 服务器永远只持有密文,无万能密钥
```

用户安装 App → 打开 → 登录/注册 或 临时聊天,全程不需要浏览器。用户不需要知道服务器 IP、API、WebSocket、数据库或域名——全部由 App 后台处理。iOS 客户端内置**国内直连双通道**(`direct.linminhao.top` Let's Encrypt 直连通道 + 主域 Cloudflare 通道),并启用 **SPKI pinning**、禁用 QUIC/HTTP-3,弱网与跨境网络下均可稳定连接。

Web 前端**不删除**,保留作为开发测试 / E2EE 协议测试 / 后端 API 测试 / 发布前兼容性测试客户端,但不再作为正式用户客户端,新功能优先在 iOS 开发。

完整定位文档:[docs/PRODUCT_DIRECTION.md](docs/PRODUCT_DIRECTION.md)

## ✨ 为什么是它

| 特点 | 说明 |
|------|------|
| 🔐 **真正的端到端加密** | 消息在客户端(CryptoKit / Web Crypto API)加密后才发送,服务器**只保存密文**。服务器没有私钥、没有万能密钥,从数据库到备份文件全部不可读明文——即使服务器被入侵,聊天记录也读不出来 |
| 📱 **原生 iOS App** | SwiftUI + CryptoKit + Keychain,私钥存 Keychain,Face ID 可选解锁,强制永久隐私模式(无水印、无关闭开关) |
| 🤖 **Android / 鸿蒙客户端** | Android 走 Capacitor 壳(公共 debug 证书 APK,免自签直接安装);HarmonyOS NEXT 走 ArkTS + ArkWeb 原生壳,三端消息协议与 iOS 字节级互通 |
| 🎯 **零门槛临时聊天** | 不用注册,创建房间 → 分享邀请 → 开聊。会话密钥不经过服务器,看完即焚(7 天自动过期,刷新即焚) |
| 👥 **邀请聊天(群聊)** | 链接 + 6 位验证码门禁,朋友点链接输入验证码即可加入;访客自动分配全局统一编号(访客001/002…),**每个人看到的编号完全一致**,对得上号 |
| 📁 **永久账号聊天** | 手机号/邮箱验证码注册(阿里云 DYPNS 平台托管码 + 邮件双通道,双账号可绑定同一个人),消息历史、已读回执、在线状态、正在输入提示、会话免打扰、加密附件、引用回复、本地消息搜索、多设备密钥包导出/导入迁移 |
| 🌐 **三端互通** | iOS / Android / HarmonyOS / Web 任意两端组合收发同一房间消息,E2EE 协议字节级兼容(有自动化交叉验证) |
| 🛡️ **隐私友好** | 无任何追踪、无广告、无明文存储。管理员后台只能看到元数据统计,看不到任何聊天内容;WS 在线列表不再广播 IP(安全审计修复) |

## 📥 安装包下载(三端统一 v1.0 发行版)

> 三个平台的**最新**安装包已合并到 [v1.0](https://github.com/93857536-pixel/LinMinHaoChat/releases/tag/v1.0) 一个 Release(标记为 Latest)。
> 早期的分散发行版(v1.9.10 ~ v1.9.28、v29-ios、v31-ios、v35-ios 等)已全部删除,`v1.0` 标签同步从 2026-09 的旧版本移至当前代码。
> ⚠️ 按约定,本仓库所有发行版**不附项目私有签名**:iOS 为未签包,需全能签/Esign/爱签等第三方工具签名后安装;鸿蒙 .hap 为本地 pki_internal 签名,无 AGC profile 时可在 DevEco Studio 导入安装或自备 .p12 重签;Android 使用公共 debug 证书(Android 系统硬性要求 APK 必须带签名),允许「安装未知应用」后直接安装。

### 版本矩阵(v1.0 发行版内置各端版本)

| 平台 | 资产文件名 | 内部版本 | 最低系统 | 安装方式 |
|---|---|---|---|---|
| 📱 iOS | `LinMinHaoChat-unsigned-v35.ipa`(~1.8 MB) | 1.9 (build 31) | iOS 17 | 未签名 IPA:全能签/爱签/Esign 等工具签名后安装 |
| 🤖 Android | `LinMinHaoChat-android-v1.9.17-debug.apk`(~10 MB) | 1.9.17(debug 证书) | Android 12+ | 允许「安装未知应用」后直接安装 |
| 🌸 HarmonyOS | `LinMinHaoChat-harmony-v1.9.16-signed.hap`(~0.4 MB) | 1.9.16(pki_internal 签名) | HarmonyOS NEXT | DevEco Studio 导入安装,或自备 AGC profile 重签 |

> 注:iOS 资产名中的 `v35` 是发行序列号(第 35 次 iOS 出包),App 内部版本为 1.9 build 31;Android/Harmony 资产名保留各自的内部版本号,保证装上去后「关于」页显示与包一致。

**SHA256 校验和(下载后请核对):**

```
122bfc3305b79132cc2501fb50ef33c4c945394a44a411ff82a40a3d7fe448b2  LinMinHaoChat-unsigned-v35.ipa
7da5135dfe88bb736c990cfba1e2cde3d6d01c5bffb61b44a300374a2f68cead  LinMinHaoChat-android-v1.9.17-debug.apk
98171fa47571c2a3ec21ef067aef97f27c1b80d77a42f3fec25d146e40ceeaf4  LinMinHaoChat-harmony-v1.9.16-signed.hap
```

**v1.0 能力清单(以 iOS build 31 / Android 1.9.17 为基准,三端协议字节级互通):** 正在输入提示(typing 帧 1.5s 防抖,状态栏显示「对方正在输入」)+ 已读回执方向修正(只有对方读了才把「我发的」标 ✓✓)+ 会话免打扰(本地持久化 `lmh.room.muted.v1`,免打扰会话不进系统通知、不更新角标)+ 头像缓存竞态修复(删头像后立即回默认,绕过 URLCache 负缓存)+ WS 订阅丢帧修复(CONNECTING 期 send 入队,onopen 后按序冲刷)+ 附件媒体渲染 / 引用回复 / 本地消息搜索 / 密钥包导出导入(多设备迁移)+ 国内直连双通道(`direct.linminhao.top` Let's Encrypt 直连 + 主域 Cloudflare)/ SPKI pinning / 禁用 QUIC(HTTP-3)+ 群聊改名 + 本地通知系统。E2E 三端交叉验证 13/13 通过。

### 📱 iOS 安装步骤(未签名 IPA → 第三方签名 → 安装)

1. 从 [v1.0 Release](https://github.com/93857536-pixel/LinMinHaoChat/releases/tag/v1.0) 下载 `LinMinHaoChat-unsigned-v35.ipa`,核对 SHA256(见上)。
2. 在 Mac 或 Windows PC 上用 **全能签 / 爱签 / Esign** 等第三方签名工具对 IPA 签名(工具内置公共描述文件,无需自建开发者账号;企业描述文件可去掉 7 天过期限制)。
3. 签名后的安装产物(描述文件 + App)传到 iPhone:数据线、AirDrop、网盘或微信文件传输均可。
4. 先安装 **描述文件**(设置 → 通用 → VPN 与设备管理 / 已下载描述文件),再安装 App;系统会提示「未受信任」→ 设置 → 通用 → 设备管理 → 信任开发者。
5. 打开 App 即自动连接后端,无需任何配置。最低 iOS 17,App 体积约 1.8 MB。

> 为什么不给私有签名:本仓库按约定**不附项目私有签名**(避免把开发者账号信息打进发布物),第三方签名工具的公共描述文件对所有设备可用,且无 7 天 / 设备 UDID 白名单限制(全能签企业签)。

### 🤖 Android 安装步骤

1. 下载 `LinMinHaoChat-android-v1.9.17-debug.apk`(公共 debug 证书签名,~10 MB,Android 12+)。
2. 安装时系统提示「未知来源应用」→ 允许;若被应用商店拦截,选择「仍然安装」。
3. 首次打开授予通知权限(群聊 / 免打扰功能依赖本地通知)。

> debug 证书是公开的可信证书(任何 Android 开发者本机默认都有),不是「未签名」——Android 系统硬性要求 APK 必须带签名,这是三端中唯一带签发的包。

### 🌸 HarmonyOS 安装步骤

1. 下载 `LinMinHaoChat-harmony-v1.9.16-signed.hap`(本地 `pki_internal` 签名,~0.4 MB)。
2. 无 AGC 开发者账号:用 **DevEco Studio → 运行 → 本地 HAP 导入** 安装,或将 .hap 直接装到已开启「HAP 调试」的 NEXT 设备。
3. 有 AGC 账号:用官方自动签名重新签一遍(仓库内 `harmony/sign-local.sh` 提供无 profile 的本地签名路径,详见 `harmony/docs/`),即可在设备市场类通道分发。

### 完整版本历史(发行序列号视角)

> 早期各端分开发行的 14 个 Release(v1.9.10 ~ v1.9.28 / v29-ios / v31-ios / v35-ios / 各 -android / -harmony)已于 2026-11-24 合并清理,仅保留 v1.0 一个 Latest;下表为完整时间线供追溯。

| 日期 | 发行 | 平台 | 主要变化 |
|---|---|---|---|
| 2026-11-24 | **v1.0(统一)** | 三端 | 三端最新包合一: iOS build 31 + Android 1.9.17 + HarmonyOS 1.9.16;早期分散发行版全部删除 |
| 2026-11-20 | v35-ios(iOS 序列号) | iOS | 正在输入 / 已读回执方向修正 / 会话免打扰 / 头像竞态 / WS 丢帧 |
| 2026-11-21 | v1.9.17-android | Android | 同基线:typing + 免打扰 + 实时通道修复(debug 证书 APK) |
| 2026-11-15 | v31-ios | iOS | 头像即时刷新 + 附件 / 引用 / 本地搜索 / 密钥包导出导入(多设备迁移) |
| 2026-11-15 | v29-ios | iOS | 同 v31 基线(序列号较早) |
| 2026-11-15 | v1.9.28 | 三端 | 三端一次性合发(iOS v28 / Android 1.9.16 / Harmony 1.9.16) |
| 2026-10-20 | v1.9.16-harmony | 鸿蒙 | 首个本地 pki_internal 签名 .hap(无 AGC profile 路线) |
| 2026-10-17 | v1.9.16-android | Android | 1.9 build 16 |
| 2026-10-16 | v1.9.15-android | Android | 发现页全功能 |
| 2026-10-06 | v1.9.14 / v1.9.13 / v1.9.12 / v1.9.10 | 混合 | 早期 E2EE 协议迭代序列 |
| 2026-09-27 | v1.0(旧,已作废) | iOS | 首版(旧 1.9 build 1,已被新 v1.0 标签取代) |

### ❓ 常见问题

- **「关于」页显示 1.9.17 / 1.9.16 / 1.9 build 31,Release 却叫 v1.0?** 不矛盾:Release 标签 `v1.0` 是发行版本号,App 内部 `CFBundleShortVersionString` / `versionName` 保持各端独立递增(1.9 build 31 是 iOS 的内部第 31 次构建,1.9.17 是 Android 内部 17 次)。Release 名统一为 v1.0,包内容保留各自真实版本,方便「关于」页溯源。
- **iOS 装完提示「未受信任的开发者」?** 走第三方签名后不会出现;若你自备描述文件签名,需在 设置 → 通用 → 设备管理 里信任对应开发者。
- **换了手机 / 重新装机,聊天记录和账号还在吗?** 账号聊天(E2EE 身份密钥存 Keychain)可用「密钥包导出 / 导入」迁移到新设备;临时聊天房间 7 天自动过期,过期后旧消息随会话密钥销毁。
- **鸿蒙 .hap 能直接发给朋友装吗?** 本地 pki_internal 签名的 .hap 只能装在调试 / 已解锁设备;正式分发请用 AGC 账号重签(DevEco 自动签名 1 分钟)。
- **Web 版还能用吗?** 能,https://chat.linminhao.top 保留为开发 / E2EE 协议 / 兼容测试入口;正式用户请装 iOS 原生 App(新功能优先在 iOS 做)。
- **如何自己起一套后端?** 见下文「快速开始 → 5 分钟本地开发模式」;生产部署教程见 `docs/DEPLOYMENT.md`(Windows Server 一套脚本:nginx + Let's Encrypt + 自启动守护 + 自动备份 + watchdog)。
- **服务器会存我的明文消息吗?** 不会。消息在客户端 CryptoKit / WebCrypto 加密成 AES-GCM-256 密文才出设备,服务器与数据库里全部是密文,没有万能密钥(细节见 `docs/SECURITY.md`)。

---

## 🚀 快速开始

### 正式产品形态 → iOS App

iOS 原生 App 是正式用户客户端:安装(见上表)→ 打开 → 登录/注册 或 临时聊天,自动连接后端,用户无需接触浏览器。

### 开发测试 / 兼容性测试 → Web 版

Web 前端保留为测试客户端,打开 **https://chat.linminhao.top** 点击「发起临时聊天」即可联调。临时聊天 7 天自动过期,刷新即焚(本地密钥立即清除)。

### 想自部署 → 5 分钟本地开发模式

```bash
# 1. 后端(dev 模式:验证码只打印到日志,不真正发短信/邮件)
cd server
npm install
npm run build
DATA_ROOT=/tmp/lmh-dev NODE_ENV=development VERIFY_CHANNEL=dev npm start

# 2. 前端(代理 /api 与 /ws 到 127.0.0.1:3000)
cd web
npm install
npm run dev
```

打开 http://localhost:5173 即可体验完整功能(开发模式下验证码显示在服务器日志里)。

### 生产部署(有服务器的人)

完整教程见 [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md):Windows Server / Linux 均适用,含
nginx 反代、HTTPS(Let's Encrypt / win-acme)、自启动守护、自动备份、日志清理、监控探针脚本。

### CI 自动部署(GitHub Actions → 阿里云 ECS)

仓库内置 `.github/workflows/deploy-server.yml`:推送触发后,在 GitHub runner 上
`npm run build` 后端 + `vite build` 前端,打 tarball,经 SSH(专用 `ci-deploy` 账号 + 部署 key)
上传到 ECS 解包重启。部署后执行**两层健康检查**:

1. 服务端权威检查:SSH 上 `curl 127.0.0.1:3000`(绕过 Cloudflare bot 管理,runner 出口被 CF 403 不算部署失败);
2. 公网 CF 域名检查(信息性,重试 6×15s 覆盖 60s watchdog 周期)。

详细排障记录(SSH 账号、YAML 折叠坑、健康检查竞态)见 [docs/ci-deploy.ps1](docs/ci-deploy.ps1) 与提交历史 `fix(ci):` 系列。

---

## ⚙️ 你需要自己填的配置(仅自部署时需要)

> 代码里**没有任何内置密钥**。以下配置全部通过环境变量或 `config/env.json` 提供,
> 敏感文件默认权限 0600,密钥(jwt.secret / otp.pepper)首次启动自动生成并持久化。
> **GitHub 仓库里不含任何真实密钥**,下面是完整清单:

| 配置项 | 环境变量 | 必填? | 说明 |
|--------|---------|-------|------|
| 站点源(防跨站) | `CORS_ORIGIN` | 生产必填 | 你的站点地址,如 `https://chat.example.com` |
| 管理员账号 | `ADMIN_USER` / `ADMIN_PASSWORD` | 否 | 不填则自动生成随机密码,写入 `config/admin.cred` |
| 验证码通道 | `VERIFY_CHANNEL` | 生产推荐 | `dev`(仅日志)/ `alibaba`(短信)|
| 阿里云短信 | `ALIBABA_ACCESS_KEY_ID` / `ALIBABA_ACCESS_KEY_SECRET` / `SMS_SIGN_NAME` / `SMS_TEMPLATE_CODE` | 短信通道时 | 阿里云 AccessKey(建议用 RAM 子账号,仅授权短信权限);验证码走 DYPNS `SendSmsVerifyCode` 平台托管码 |
| 邮件通道 | `MAIL_CHANNEL=smtp` + `MAIL_SMTP_HOST` / `MAIL_SMTP_PORT` / `MAIL_USER` / `MAIL_PASS` | 邮件通道时 | `MAIL_PASS` 是 **SMTP 授权码**(在邮箱设置里开启 SMTP 服务生成,**不是邮箱登录密码**)|
| 阿里云邮件 | `MAIL_CHANNEL=directmail` + `DM_ACCOUNT_NAME` / `DM_FROM_ALIAS` | directmail 时 | 阿里云 DirectMail |
| 数据目录 | `DATA_ROOT` | 否 | 默认 `/opt/linminhao`(Linux)/ `C:\opt\linminhao`(Windows)|
| 端口/绑定 | `PORT` / `BIND_HOST` | 否 | 默认 `3000` / `127.0.0.1`(生产由 nginx 反代,不暴露公网)|

**完整环境变量说明**:[docs/ENVIRONMENT.md](docs/ENVIRONMENT.md)

> 🔑 部署完成后,在 `config/env.json` 填你的值(或导出环境变量),重启服务即生效。
> 示例配置模板也在 [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) 里,直接复制改值。

---

## 🔒 E2EE 安全原则(为什么可以放心用)

1. **密钥只在设备里**:临时聊天的会话密钥放在分享链接的 `#fragment`(不会发送到服务器,nginx 日志、CDN、代理都看不到);账号聊天的身份密钥在 iOS 存 Keychain,支持 PBKDF2 密钥包导出/导入实现多设备迁移
2. **服务器永远只见密文**:消息用 AES-GCM-256 加密,密钥派生走 HKDF-SHA256,每次消息的 AAD 绑定 `roomId:seq:ts` 防重放/篡改
3. **身份密钥体系**:ECDH P-256 协商会话密钥 + Ed25519 签名,三端(iOS CryptoKit / Web WebCrypto)交叉验证字节级兼容
4. **无万能密钥**:管理员、服务器运维、数据库管理员都无法解密任何消息
5. **身份与消息解耦**:访客匿名编号由服务器统一分配(便于对号入座),但编号≠身份,配合 E2EE 无法关联到真实用户
6. **强制隐私模式**:iOS 端永久开启,无水印、无关闭开关;WS 在线列表不广播客户端 IP

## 📺 三端客户端说明

### iOS(SwiftUI,正式客户端)

```
ios/
  project.yml             xcodegen 工程定义(唯一工程源)
  LinMinHaoChat/
    App/                  入口 + 后端地址 + 隐私模式 + 全局状态(登录态存 Keychain)
    Crypto/               与 web/src/crypto 协议字节级兼容(HKDF-SHA256 + AES-GCM,
                          AAD=roomId:seq:ts;ECDH P-256 + Ed25519 + 密钥包导出)
    Keychain/             私钥/令牌存取
    Networking/           APIClient + WebSocketClient(国内直连双通道 + SPKI pinning)
    ViewModels/           临时聊天/账号聊天全链路
    Views/                Home / TempRoom / Chat / Login / Settings / 隐私模糊层
  verify/                 CryptoKit ↔ WebCrypto 协议交叉验证(harness)
  pack-ipa.sh             未签名 IPA 打包
```

构建:`xcodegen generate && xcodebuild -project LinMinHaoChat.xcodeproj -scheme LinMinHaoChat -destination 'generic/platform=iOS Simulator' build`(免签名)。
详见 [ios/README.md](ios/README.md)。

### Android(Capacitor 壳)

Web 前端打包进 Capacitor(`web/android/`),输出公共 debug 证书 APK(Android 12+)。
与 iOS/Web 共享同一套 E2EE 消息协议,三端同房间互通。

### HarmonyOS NEXT(ArkTS + ArkWeb)

```
harmony/
  entry/src/main/ets/     pages / deeplink / pns / voice / bridge
  sign-local.sh           本地 pki_internal 签名(无 AGC profile 时)
```

ArkWeb 承载 E2EE 聊天/语音/深链,一键登录按设备能力降级。详见 [harmony/docs/](harmony/docs/)。

### Web(React 18,测试/兼容客户端)

```
web/src/
  crypto/                 keys(身份密钥) / session(会话密钥) / message(消息加密)
  pages/                  Home / TempChat / InviteChat / Login / Chat / Admin / About
  api.ts                  REST 客户端
  ws.ts                   WebSocket 客户端(心跳/断线重连)
```

## 🛠️ 后端与运维

```
server/src/
  index.ts       入口(HTTP+WS)
  app.ts         Express 装配(CORS/安全头/限流)
  config.ts      配置加载(config/env.json + 环境变量)
  db.ts          SQLite(better-sqlite3)初始化/表结构/自动迁移
  storage.ts     密文文件归档存储层
  routes/        auth / keys / temp / chat / invite / attachments / admin
  ws.ts          WebSocket 网关(实时推送/在线统计/正在输入)
  otp.ts         验证码逻辑(限流/尝试次数/过期)
  channels.ts    阿里云 DYPNS 短信 / DirectMail / SMTP 通道
deploy/          nginx 配置 / 自启动 / 备份 / 证书 / 监控 / watchdog 等 PowerShell+CMD 脚本(Windows Server 一套)
```

## 📐 技术栈

| 层 | 技术 |
|---|---|
| iOS 客户端 | Swift 5 / SwiftUI / CryptoKit / Keychain / xcodegen |
| Android 客户端 | Capacitor 6(壳)+ 公共 debug 证书 |
| 鸿蒙客户端 | HarmonyOS NEXT / ArkTS / ArkWeb(DevEco) |
| Web 前端 | React 18 + TypeScript 5 + Vite + Web Crypto API |
| 后端 | Node.js 22 + Express + ws(WebSocket)+ TypeScript |
| 存储 | SQLite(better-sqlite3,索引/元数据)+ 文件系统(密文归档) |
| 加密 | AES-GCM-256 / HKDF-SHA256 / ECDH P-256 / Ed25519 / PBKDF2 |
| 反代/HTTPS | Nginx + Let's Encrypt(win-acme;国内直连通道 direct.linminhao.top)|
| 运维 | Windows Task Scheduler / systemd(自启动、守护、备份、日志清理、watchdog)|
| CI/CD | GitHub Actions(构建 → ECS SSH 部署 → 两层健康检查) |

## 📚 文档

- [docs/PRODUCT_DIRECTION.md](docs/PRODUCT_DIRECTION.md) — 产品方向总纲(客户端定位)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 架构与 E2EE 密钥生命周期
- [docs/SECURITY.md](docs/SECURITY.md) — 安全设计细节
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — 生产部署教程(Windows/Linux)
- [docs/STORAGE.md](docs/STORAGE.md) — 数据存储设计
- [docs/API.md](docs/API.md) — REST API 与 WebSocket 参考
- [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) — 环境变量完整参考
- [docs/BACKUP.md](docs/BACKUP.md) — 备份与恢复
- [docs/TESTING.md](docs/TESTING.md) — 测试与验证
- [docs/ci-deploy.ps1](docs/ci-deploy.ps1) — CI 部署脚本与排障
- [ios/README.md](ios/README.md) — iOS 客户端构建与协议验证
- [harmony/docs/](harmony/docs/) — 鸿蒙端桥接协议与状态

## 🕘 近期版本亮点

- **v1.0 统一发行版(2026-11-24,三端最新包合一)**:iOS = build 31(发行序列号 v35)、Android = 1.9.17(debug 证书)、HarmonyOS = 1.9.16(pki_internal 本地签名),三个安装包合并入 [v1.0 Release](https://github.com/93857536-pixel/LinMinHaoChat/releases/tag/v1.0),早期分散发行版全部删除,`v1.0` 标签指向当前代码。能力基线:iOS build 31 的正在输入提示(typing 帧 1.5s 防抖)、已读回执方向修正(只认对方 read 帧)、会话免打扰(本地持久化 / 免打扰会话不进通知不角标)、头像缓存竞态修复(绕过 URLCache 负缓存,删头像立即回默认)、WS 订阅丢帧修复(CONNECTING 期 send 入队,onopen 后按序冲刷,实时通道不再只剩 15s 轮询兜底);群聊改名 + 本地通知、账号绑定手机+邮箱双登录、短信验证码改 DYPNS 平台托管码、安全审计(WS 不广播 IP + keys 路由限流)、国内直连双通道 + SPKI pinning + 禁用 QUIC。E2E 双端交叉验证 13/13 通过。
- **CI(2026-11)**:ECS 自动部署工作流全通(专用 ci-deploy 账号、YAML 块标量修 sshd 1332 坑、6×15s 权威健康检查覆盖 watchdog 周期)

## 📄 License

[MIT](LICENSE) © 2026 [93857536-pixel](https://github.com/93857536-pixel)
