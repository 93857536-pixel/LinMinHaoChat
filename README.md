# LinMinHao Chat 🔐

**端到端加密(E2EE)聊天 · 免注册临时聊天 + 永久账号聊天 · 开箱即用**

> 🚀 在线体验:https://linminhao.top(不想折腾?直接打开就用,无需注册即可发起临时加密聊天)

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Node](https://img.shields.io/badge/Node-22+-blue.svg)
![React](https://img.shields.io/badge/React-18-blue.svg)
![TypeScript](https://img.shields.io/badge/TypeScript-5-blue.svg)

---

## ✨ 为什么是它

| 特点 | 说明 |
|------|------|
| 🔐 **真正的端到端加密** | 消息在浏览器里用 Web Crypto API 加密后才发送,服务器**只保存密文**。服务器没有私钥、没有万能密钥,从数据库到备份文件全部不可读明文——即使服务器被入侵,聊天记录也读不出来 |
| 🎯 **零门槛临时聊天** | 不用注册、不用下载 App,创建房间 → 分享链接 → 开聊。会话密钥藏在链接里(URL fragment),**不经过服务器**,看完即焚 |
| 👥 **邀请聊天(群聊)** | 链接 + 6 位验证码门禁,朋友扫码/点链接输入验证码即可加入;访客自动分配全局统一编号(访客001/002…),**每个人看到的编号完全一致**,对得上号 |
| 📱 **永久账号聊天** | 手机/邮箱验证码注册(支持短信/邮件双通道),消息历史、已读回执、在线状态、加密附件、多设备密钥迁移 |
| 🛡️ **隐私友好** | 无任何追踪、无广告、无明文存储。管理员后台只能看到元数据统计,看不到任何聊天内容 |
| 🌍 **跨平台** | 纯 Web 应用,任何有浏览器的设备(电脑/手机/平板)都能用,无需安装 |

## 🚀 快速开始

### 不想折腾 → 直接用

打开 **https://linminhao.top** ,点击「发起临时聊天」→ 分享链接给朋友 → 开聊。
零注册、零配置、端到端加密。临时聊天 7 天自动过期,刷新即焚(本地密钥立即清除)。

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
nginx 反代、HTTPS(Let's Encrypt)、自启动守护、自动备份、日志清理。

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
| 阿里云短信 | `ALIBABA_ACCESS_KEY_ID` / `ALIBABA_ACCESS_KEY_SECRET` / `SMS_SIGN_NAME` / `SMS_TEMPLATE_CODE` | 短信通道时 | 阿里云 AccessKey(建议用 RAM 子账号,仅授权短信权限)|
| 邮件通道 | `MAIL_CHANNEL=smtp` + `MAIL_SMTP_HOST` / `MAIL_SMTP_PORT` / `MAIL_USER` / `MAIL_PASS` | 邮件通道时 | `MAIL_PASS` 是 **SMTP 授权码**(在邮箱设置里开启 SMTP 服务生成,**不是邮箱登录密码**)|
| 阿里云邮件 | `MAIL_CHANNEL=directmail` + `DM_ACCOUNT_NAME` / `DM_FROM_ALIAS` | directmail 时 | 阿里云 DirectMail |
| 数据目录 | `DATA_ROOT` | 否 | 默认 `/opt/linminhao`(Linux)/ `C:\opt\linminhao`(Windows)|
| 端口/绑定 | `PORT` / `BIND_HOST` | 否 | 默认 `3000` / `127.0.0.1`(生产由 nginx 反代,不暴露公网)|

**完整环境变量说明**:[docs/ENVIRONMENT.md](docs/ENVIRONMENT.md)

> 🔑 部署完成后,在 `config/env.json` 填你的值(或导出环境变量),重启服务即生效。
> 示例配置模板也在 [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) 里,直接复制改值。

---

## 🔒 E2EE 安全原则(为什么可以放心用)

1. **密钥只在浏览器里**:会话密钥放在分享链接的 `#fragment`(不会发送到服务器,nginx 日志、CDN、代理都看不到),或存储在用户本地设备
2. **服务器永远只见密文**:消息用 AES-GCM 加密,密钥派生走 HKDF,每次消息的 AAD 绑定 `roomId:seq:ts` 防重放/篡改
3. **无万能密钥**:管理员、服务器运维、数据库管理员都无法解密任何消息
4. **身份与消息解耦**:访客匿名编号由服务器统一分配(便于对号入座),但编号≠身份,配合 E2EE 无法关联到真实用户

## 🛠️ 技术栈

- 前端:React 18 + TypeScript + Vite + Web Crypto API
- 后端:Node.js 22 + Express + WebSocket(ws)
- 存储:SQLite(better-sqlite3,索引/元数据)+ 文件系统(密文归档)
- 反代/HTTPS:Nginx + Let's Encrypt(win-acme)
- 运维:Windows Task Scheduler / systemd(自启动、守护、备份、日志清理)

## 📁 目录结构

```
server/            Node.js 后端(TypeScript)
  src/
    index.ts       入口(HTTP+WS)
    app.ts         Express 装配(CORS/安全头/限流)
    config.ts      配置加载(config/env.json + 环境变量)
    db.ts          SQLite 初始化/表结构/自动迁移
    storage.ts     密文文件存储层
    middleware.ts  认证/安全头/日志
    routes/        auth / keys / temp / chat / invite / attachments / admin
    ws.ts          WebSocket 网关(实时推送/在线统计)
    otp.ts         验证码逻辑(限流/尝试次数/过期)
    channels.ts    阿里云 SMS / DirectMail / SMTP 通道
web/               React 前端
  src/
    crypto/        keys(身份密钥) / session(会话密钥) / message(消息加密)
    pages/         Home / TempChat / InviteChat / Login / Chat / Admin / About
    api.ts         REST 客户端
    ws.ts          WebSocket 客户端(心跳/断线重连)
deploy/            nginx 配置 / 运维脚本(自启动/备份/证书/监控)
docs/              文档:架构 / 安全 / 部署 / API / 环境变量 / 备份 / 测试
```

## 📚 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 架构与 E2EE 密钥生命周期
- [docs/SECURITY.md](docs/SECURITY.md) — 安全设计细节
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — 生产部署教程(Windows/Linux)
- [docs/STORAGE.md](docs/STORAGE.md) — 数据存储设计
- [docs/API.md](docs/API.md) — REST API 与 WebSocket 参考
- [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) — 环境变量完整参考
- [docs/BACKUP.md](docs/BACKUP.md) — 备份与恢复
- [docs/TESTING.md](docs/TESTING.md) — 测试与验证

## 📄 License

[MIT](LICENSE) © 2026 [93857536-pixel](https://github.com/93857536-pixel)
