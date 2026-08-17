# 数据存储(STORAGE)

## 设计原则

- 聊天正文**只以密文文件**保存,永不进入数据库明文
- 数据库只保存:索引、元数据、密文文件路径
- 数据目录与站点代码分离,不经过 nginx 静态路由,只能通过带认证的 API 访问
- 文件权限最小化(Windows:Administrators+SYSTEM;Linux 对应 0700/0600)

## 目录结构(服务器实际路径)

```
C:\opt\linminhao\
├── db\chat.db                  SQLite(WAL)
├── messages\YYYY\MM\DD\       消息密文 <roomId>_<seq>.enc
├── attachments\YYYY\MM\DD\    附件密文 <attId>.enc
├── users\                      预留
├── sessions\                   预留
├── backups\chat-backup-*.zip   每日备份
├── logs\                       app/error/dev-otp/watchdog 日志
├── config\env.json             生产配置(0600)
└── data\config\                jwt.secret / otp.pepper / admin.cred(0600)
```

## 密文文件格式

`.enc` 文件内容 = `base64(iv || ciphertext || gcm-tag)`(即客户端 payload 的 ct 字段原文)。
文件名由服务器生成(`roomId`/`attId` 白名单校验),杜绝路径遍历。

## SQLite 表(仅元数据)

| 表 | 内容 |
|----|------|
| users | id、phone_hash/email_hash、脱敏显示值、handle、banned、登录时间 |
| user_keys | 每设备公钥(ed25519_pub、ecdh_pub)、加密导出包 export_pkg |
| rooms / room_members | 会话与成员(加密群名 name_enc) |
| room_keys | wrappedKey 密文(每成员每设备) |
| temp_rooms | 临时房间元数据(过期时间、状态、消息数) |
| messages | id、room_id、seq、kind、sender、**cipher_path**、iv、aad、ts、read_by |
| otp_codes | target_hash、**code_hash(HMAC)**、过期、尝试次数、used |
| sessions | sessionId 哈希、user_id、过期 |
| admin_audit | 管理员操作审计 |

> messages 表不含明文:正文在 cipher_path 指向的 .enc 文件,且为加密字节。
> iv/aad 是公开参数(配合 GCM 认证),本身不泄露内容。

## 目录遍历防护

- `CipherStore.readCipher()`:规范化路径后必须 `messages/` 或 `attachments/` 前缀,且绝对路径 containment 检查
- 文件名组件全部服务器生成(roomId/seq/attId 正则白名单)

## 访问控制

- 消息密文:仅房间成员(账号聊天)或持有房间 ID(临时聊天,叠加过期+条数+限流)
- 附件:仅房间成员;下载强制 `Content-Disposition: attachment` + `nosniff`
- 数据目录:nginx 无任何指向 messages/attachments/db 的 location

## 磁盘规划

- 2GB RAM 机器,密文文件极小(文本消息每条 <200B),50GB 磁盘足够长期使用
- 附件上限 10MB/个;可监控 `admin/stats` 的 disk 字段

## 备份(另见 BACKUP.md)

每日 03:00 由计划任务打包 `db + messages + attachments + env.json` → `backups/chat-backup-<ts>.zip`,保留 14 份。
备份内容仍为密文(E2EE 不因备份而弱化)。
