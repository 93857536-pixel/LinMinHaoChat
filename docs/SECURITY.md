# 安全设计(SECURITY)

## 威胁模型

- 服务器完全不可信(管理员/被入侵/日志泄露均不可读明文)
- 客户端设备受信(私钥在 IndexedDB)
- 传输层攻击(中间人)由 TLS 抵御

## E2EE 保障

1. 服务器零明文:数据库、密文文件、备份、日志均不含消息明文(验收见 TESTING.md)
2. 服务器零私钥:私钥只在浏览器 IndexedDB
3. 认证加密:AES-256-GCM + 每消息独立 IV + HKDF 派生密钥 + AAD 防篡改
4. 密钥分发:ECDH P-256 + HKDF;wrappedKey 仅成员可解
5. 临时聊天密钥带外(fragment)传输,服务器不可见

## 传输安全

- HTTPS 强制(HTTP 301 → HTTPS);HSTS `max-age=31536000; includeSubDomains`
- TLS 1.2/1.3,仅强套件;WSS 走同一通道
- 验证码、登录、消息均禁止明文 HTTP 传输(生产)

## 认证与凭证

- 验证码:6 位数字,5 分钟有效,错误 5 次作废,用后立即失效;DB 存 HMAC-SHA256(pepper, code),**不存明文**;pepper 独立于 JWT secret
- JWT:HS256,secret 自动生成于 `data/config/jwt.secret`(0600),不落仓库
- 管理员:scrypt 校验,无默认密码(首启自动生成随机密码写入 admin.cred,提示修改)
- AccessKey 等阿里云凭证:仅 `config/env.json`(0600),绝不进前端/代码/Git

## 应用层防护

| 项 | 实现 |
|----|------|
| CSRF | 全 API Bearer token 认证(无 cookie 认证);CORS 仅允许本站源 |
| XSS | CSP(nginx 层)+ React 默认转义 + 输入长度/字符限制 |
| SQLi | better-sqlite3 预编译语句,全部参数化 |
| 路径遍历 | cipher_path 白名单前缀校验 + 绝对路径 containment 检查;文件名为服务器生成 |
| SSRF | 服务端不发起任意 URL 请求(仅阿里云 SDK 固定 endpoint) |
| 请求体限制 | API 128KB;附件 10MB;WS 帧 128KB |
| 限流/爆破 | 见 ARCHITECTURE §5;验证码目标级 5 次/小时 |
| 文件上传 | MIME 白名单声明 + 大小限制;下载强制 `attachment` + `nosniff`,服务器不解密不渲染 |

## 敏感数据最小化

- 日志:不记录 body/验证码/token;手机号 `138****1234`、邮箱 `abc***@example.com` 脱敏
- 验证码:dev 通道仅写入 `logs/dev-otp.log`(0600,生产切 alibaba 后不再产生)
- 用户表只存脱敏后的手机/邮箱 + 哈希

## 网络与端口

- ECS 安全组:仅 22/80/443(建议 22 限制来源 IP)
- 后端监听 127.0.0.1:3000,不暴露公网;SQLite 无网络端口
- 数据目录(密文)不经过 nginx 静态路由,只能通过带认证的 API 读取

## 密钥清单(服务器)

| 密钥 | 位置 | 权限 |
|------|------|------|
| JWT secret | `data/config/jwt.secret` | 0600 |
| OTP pepper | `data/config/otp.pepper` | 0600 |
| 管理员密码 | `config/env.json` / `data/config/admin.cred` | 0600 |
| 阿里云 AccessKey | `config/env.json` | 0600 |

## 管理员边界

管理员可:统计、封禁用户/房间、删除密文、看日志与元数据。
管理员**不能**:解密任何消息(无密钥)、查看明文内容。
