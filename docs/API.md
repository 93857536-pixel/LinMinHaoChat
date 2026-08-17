# API 参考(API.md)

Base URL:生产 `https://<你的域名>/api`(过渡期 `http://<你的服务器IP>/api`)
所有请求/响应 JSON。错误格式 `{"error":"<code>"}`(部分带附加字段)。
认证:`Authorization: Bearer <JWT>`(用户端);管理员同法但 role=admin。

## 公共

| 方法/路径 | 说明 |
|-----------|------|
| GET /api/health | 健康检查(无需认证) |

## 认证(auth)

| 方法/路径 | 请求体 | 说明 |
|-----------|--------|------|
| POST /auth/send-code | `{type:'sms'\|'email', target}` | 发送验证码;60s 间隔;返回 `{expiresInSec:300}` |
| POST /auth/register | `{type,target,code,handle?,deviceId?,ed25519Pub?,ecdhPub?}` | 注册(验证码);返回 `{token,sessionId,user}` |
| POST /auth/login | `{type,target,code,deviceId?,ed25519Pub?,ecdhPub?}` | 登录;返回同上 |
| POST /auth/logout | `{sessionId}` | 作废会话 |

限流:IP 30 次/10min;错误码 `invalid_code` / `too_many_attempts` / `rate_limited`(含 retryAfterSec)。

## 密钥(keys,需认证)

| 方法/路径 | 说明 |
|-----------|------|
| POST /keys/register | `{ed25519Pub,ecdhPub,deviceId}` 上传/更新公钥 |
| POST /keys/export-package | `{pkg,deviceId}` 保存加密导出包(≤64KB) |
| GET /keys/export-package?deviceId= | 拉取加密导出包 |
| GET /keys/public/:userId | 某用户全部设备公钥 |
| GET /keys/my | 我的设备列表 |
| GET /keys/lookup?q= | 按用户 ID 查找(限流 60/min/IP) |

## 临时聊天(temp)

| 方法/路径 | 说明 |
|-----------|------|
| POST /temp/rooms | 创建房间(限流 10/h/IP)→ `{roomId,expiresAt}`(7 天) |
| GET /temp/rooms/:id | 房间元数据(含 expired/status) |
| POST /temp/rooms/:id/join | 加入 → `{anonId,wsToken}`(一次性,5 分钟) |
| POST /temp/rooms/:id/messages | `{iv,cipher,seq,anonId?,meta?}` 发送密文;409 表示 seq 冲突并返回最新 seq |
| GET /temp/rooms/:id/messages?afterSeq=&limit= | 拉历史密文(分页 ≤500) |
| POST /temp/rooms/:id/leave | 退出(服务器保留归档) |

房间限制:7 天过期;2000 条上限;`room_banned`/`room_expired`/`room_full` 错误码。

## 账号聊天(chat,需认证)

| 方法/路径 | 说明 |
|-----------|------|
| GET /chat/rooms | 我的会话列表(含 unread) |
| POST /chat/rooms | `{type:'dm'\|'group',memberIds[],nameEnc?,wrappedKeys[]}` 创建;dm 幂等复用 |
| GET /chat/rooms/:id | 会话详情 |
| GET /chat/rooms/:id/keys?deviceId= | 我的 wrappedKeys |
| POST /chat/rooms/:id/keys | `{userId,deviceId,wrappedKey}` 追加密钥(新设备/新成员) |
| POST /chat/rooms/:id/add-member | `{userId}` 加群成员 |
| POST /chat/rooms/:id/messages | `{iv,cipher,seq,kind?,meta?}` 发送密文(同 409 语义) |
| GET /chat/rooms/:id/messages?afterSeq=&limit= | 历史密文分页 |
| POST /chat/rooms/:id/read | `{lastSeq}` 已读回执 |
| GET /chat/rooms/:id/online | 在线成员 ID 列表 |

## 附件(attachments,需认证)

| 方法/路径 | 说明 |
|-----------|------|
| POST /attachments?roomId=&declaredMime= | raw body 上传加密附件(≤10MB)→ `{attId,size}` |
| GET /attachments/:id | 下载密文(仅成员;强制 attachment) |

## 管理员(admin)

| 方法/路径 | 说明 |
|-----------|------|
| POST /admin/login | `{username,password}` → admin JWT(12h) |
| GET /admin/stats | 用户/在线/房间/消息/磁盘/运行状态 |
| GET /admin/users?page= | 用户列表(脱敏) |
| POST /admin/users/:id/ban | `{ban,reason?}` 封禁/解封 |
| DELETE /admin/users/:id | 删除账号+其会话密文 |
| GET /admin/temp-rooms?page= | 临时房间元数据 |
| POST /admin/temp-rooms/:id/ban | 封禁/恢复房间 |
| DELETE /admin/temp-rooms/:id | 删除房间全部密文 |
| GET /admin/rooms/:id/messages | 消息**元数据**(无密文内容) |
| GET /admin/logs?lines= | 错误日志尾部 |
| GET /admin/audit | 操作审计 |
| POST /admin/rotate-password | 轮换管理员密码(写入 env.json) |

> 管理员接口永不返回密文内容 —— E2EE 边界。

## WebSocket(/ws)

连接参数:`?token=<JWT>`(账号)或 `?wsToken=<一次性短令牌>`(临时聊天)。

客户端 → 服务器:`{type:'subscribe',roomId}` / `{type:'read',roomId,lastSeq}` / `{type:'ping'}`

服务器 → 客户端:
- `hello`(连接建立,含 serverTime)
- `subscribed`
- `msg` `{type:'msg',roomId,seq,id,senderId?|anonId?,ts,kind?}` —— **事件通知**,密文经 REST 拉取
- `read` `{userId,lastSeq}`
- `presence` `{roomId,online:[...]}`
- `pong`
- `error`

关闭码:4001 未认证 / 4003 封禁 / 4008 超时。
限制:单帧 ≤128KB;90s 无活动断开;心跳 25s。
