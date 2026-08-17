# 架构与 E2EE 密钥生命周期

## 1. 系统总览

```
浏览器(客户端)
  │  Web Crypto:Ed25519 身份 + ECDH P-256 交换 + AES-256-GCM 加密
  │  HTTPS / WSS(生产)
  ▼
Nginx(反代 + 静态托管 + TLS 终止)
  │  /api/* → 127.0.0.1:3000    /ws → 127.0.0.1:3000(Upgrade)
  ▼
Node.js(Express + ws)
  │  · 认证(JWT) · 验证码(阿里云 SMS/DirectMail) · 限流
  │  · 消息只做中转:写入密文文件 + 索引元数据,广播事件
  ▼
SQLite(chat.db)                    文件系统
  用户/密钥/房间/索引/会话      messages/YYYY/MM/DD/*.enc
  (无明文,只有密文路径/iv/aad)  attachments/YYYY/MM/DD/*.enc
```

## 2. E2EE 密钥体系

### 2.1 身份密钥(每设备)

| 密钥 | 算法 | 用途 |
|------|------|------|
| 签名密钥对 | Ed25519 | 设备身份(预留消息签名) |
| 交换密钥对 | ECDH P-256 | 会话密钥的包装/解包 |

- 生成:注册/首次登录时 `crypto.subtle.generateKey`,**私钥只存浏览器 IndexedDB**(库名 `lmh-keys`),永不上传
- 服务器只保存公钥(`ed25519_pub`、`ecdh_pub`,base64)
- 设备 ID:每设备随机生成,随公钥上报

### 2.2 会话密钥(每会话)

- 私聊/群聊:创建者生成 32 字节随机 `sessionKey`
- 分发:对每个成员(按设备)执行
  `ECDH(myPriv, memberPub) → HKDF-SHA256 → AES-GCM 加密 sessionKey`
  产出 `wrappedKey = {v, iv, ct, pk}`(pk = 包装者公钥,供对方解包)
- 存储:wrappedKey 上传服务器 `room_keys` 表。**服务器无法还原 sessionKey**
- 解包:成员拉取自己的 wrappedKey,用 `ECDH(memberPriv, pk)` 还原 sessionKey
- 生命周期:sessionKey 在客户端内存缓存(不落盘),刷新页面后需重新解包;会话删除即失效

### 2.3 消息加密

```
加密:key_m = HKDF(sessionKey, salt=iv, info=`lmh-msg-v1:${roomId}:${seq}`)
      ciphertext = AES-256-GCM(key_m, iv=random12B, plaintext, AAD=`${roomId}:${seq}:${ts}`)
      payload = {iv: base64, ct: base64(iv||ct||tag)}
```

- **每条消息独立随机 IV**,杜绝 nonce 重用
- **AAD 绑定**房间/序号/时间戳:服务器篡改任一字段,GCM 认证立即失败
- 客户端发送前向服务器提交预估 `seq`,服务器校验 `seq == msg_count+1`,冲突返回 409 并告知最新 seq,客户端重新加密重试 —— 保证 AAD 中的 seq 与服务器记录严格一致
- 明文结构:`{"t":"文本"}` 或 `{"f":{"attId","name","size","mime"}}`(附件元数据)

### 2.4 临时聊天密钥(带外传输)

- 创建者生成 sessionKey,放入分享链接 fragment:`/t/<roomId>#k=<base64url>`
- **URL fragment 不经过 HTTP 请求**,nginx/服务器/日志均不可见 → 服务器无密钥
- 加入者从 `location.hash` 提取密钥,双方用同一密钥加密
- 刷新即焚:页面检测到本会话 active 标记 → 清除 fragment + sessionStorage + 内存密钥,界面清空;服务器密文归档保留
- 过期:房间 7 天;超期拒绝新消息,但归档保留

### 2.5 多设备迁移(口令加密导出包)

- 导出:`PBKDF2-SHA256(250k) → AES-GCM` 加密私钥 JWK 包,JSON 下载并可选上传服务器(`export_pkg`)
- 导入:新设备输入口令解密包,恢复身份密钥
- 服务器只中转加密包,无法解密

## 3. 认证与会话

- 验证码登录(手机/邮箱),无密码
- JWT(HS256,`jose` 库)7 天有效,`Authorization: Bearer`;会话表存 sessionId 哈希
- 管理员:独立 JWT(role=admin)12 小时;凭据 scrypt 校验

## 4. 实时通信(WebSocket)

- 路径 `/ws`;账号连接带 JWT;临时连接带一次性短令牌(join 颁发,5 分钟,用后即废)
- 消息帧 `{type: msg|read|presence|subscribe|ping|pong|hello|error}`
- **WS 只做事件通知**(含 seq/roomId),密文走 REST 拉取 —— 简化一致性,避免 WS 超限
- 心跳 25s,90s 无活动断开;单帧上限 128KB
- 在线状态:按房间聚合,广播 presence

## 5. 限流(内存滑动窗口)

| 动作 | 限制 |
|------|------|
| 验证码发送(IP) | 60 次/小时,超限封禁 1h |
| 验证码发送(目标) | 5 次/小时;同一目标 60s 间隔 |
| 认证接口(IP) | 30 次/10 分钟 |
| 管理员登录(IP) | 5 次/10 分钟 |
| 发消息(IP) | 60 次/分钟 |
| 拉历史(IP) | 120 次/分钟 |

## 6. 部署拓扑(生产)

- 单机单进程(Node 监听 127.0.0.1:3000,不对外)
- Nginx 承担:TLS、静态资源、反代、WS 升级、安全头、HTTP→HTTPS 跳转
- 进程托管:Task Scheduler(开机自启)+ watchdog(每分钟拉起)
- 备份:每日 03:00 zip(DB + 密文 + env.json),保留 14 份
