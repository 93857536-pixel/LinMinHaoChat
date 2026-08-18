# LinMinHao Chat

**端到端加密(E2EE)临时通讯 + 永久账号通讯应用(原生 iOS App 主客户端 + Web 测试客户端)**

> 📌 产品定位:https://linminhao.top 为后端基础设施,Web 前端为测试/兼容客户端,正式用户客户端是原生 iOS App。详见 [PRODUCT_DIRECTION.md](PRODUCT_DIRECTION.md)

## 功能

| 模式 | 说明 |
|------|------|
| 临时聊天 | 无需注册,一键创建,分享链接(密钥在 URL fragment,不经过服务器)。刷新即焚:本地密钥与记录立即清除;服务器保留加密归档 |
| 账号聊天 | 手机/邮箱验证码注册登录,永久保留。支持私聊、消息历史、已读回执、在线状态、加密附件、多设备密钥迁移 |

## E2EE 原则

服务器可以保存聊天数据,但保存的**永远是密文**。服务器没有私钥、没有万能密钥,
从数据库到密文文件到备份,全部不可读明文。管理员后台也只能看到元数据与统计。

## 技术栈

- 前端:React 18 + TypeScript + Vite + Web Crypto API
- 后端:Node.js 22 + Express + WebSocket(ws)
- 存储:SQLite(better-sqlite3,索引/元数据)+ 文件系统(密文)
- 反代/HTTPS:Nginx for Windows + Let's Encrypt(win-acme)
- 运维:Windows Task Scheduler(自启动/守护/备份/日志清理)

## 目录结构

```
server/            Node.js 后端(TypeScript)
  src/
    index.ts       入口(HTTP+WS)
    app.ts         Express 装配
    config.ts      配置加载(config/env.json)
    db.ts          SQLite 初始化/表结构
    storage.ts     密文文件存储层
    middleware.ts  认证/安全头/日志
    routes/        auth / keys / temp / chat / attachments / admin
    ws.ts          WebSocket 网关
    otp.ts         验证码逻辑
    channels.ts    阿里云 SMS / DirectMail 通道
web/               React 前端
  src/
    crypto/        keys(身份密钥) / session(会话密钥) / message(消息加密)
    pages/         Home / TempChat / Login / Chat / Admin / About
    api.ts         REST 客户端
    ws.ts          WebSocket 客户端
deploy/            nginx 配置 / 运维脚本(自启动/备份/证书)
docs/              本文档目录
```

## 快速开始(开发)

```bash
# 后端
cd server && npm install && npm run build && DATA_ROOT=/tmp/lmh-dev NODE_ENV=development VERIFY_CHANNEL=dev npm start
# 前端(代理 /api 与 /ws 到 127.0.0.1:3100)
cd web && npm install && npm run dev
```

## 相关文档

- [PRODUCT_DIRECTION.md](PRODUCT_DIRECTION.md) — **产品定位总纲(iOS App 主客户端)**

- [ARCHITECTURE.md](ARCHITECTURE.md) — 架构与 E2EE 密钥生命周期
- [SECURITY.md](SECURITY.md) — 安全设计
- [DEPLOYMENT.md](DEPLOYMENT.md) — 生产部署(Windows Server)
- [STORAGE.md](STORAGE.md) — 数据存储
- [API.md](API.md) — API 与 WebSocket 参考
- [ENVIRONMENT.md](ENVIRONMENT.md) — 环境变量
- [BACKUP.md](BACKUP.md) — 备份与恢复
- [TESTING.md](TESTING.md) — 测试

## 已知限制

- 消息搜索:因 E2EE,服务器无法按明文搜索;搜索需在客户端本地进行(历史密文拉取后解密检索)
- 附件类型校验:服务器只能校验大小与客户端声明的 MIME 白名单,无法验证密文内的真实类型(E2EE 特性)
- 临时聊天房间:7 天过期,单房间上限 2000 条消息
