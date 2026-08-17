# 环境变量与环境配置(ENVIRONMENT)

## 配置文件

生产配置位于服务器 `C:\opt\linminhao\config\env.json`(权限 0600)。
优先级:进程环境变量 > env.json > 内置默认。

示例:

```json
{
  "NODE_ENV": "production",
  "PORT": "3000",
  "BIND_HOST": "127.0.0.1",
  "DATA_ROOT": "C:\\opt\\linminhao",
  "VERIFY_CHANNEL": "dev",
  "MAIL_CHANNEL": "smtp",
  "MAIL_SMTP_HOST": "smtp.foxmail.com",
  "MAIL_SMTP_PORT": "465",
  "MAIL_USER": "<你的发信邮箱,如 you@example.com>",
  "MAIL_PASS": "<SMTP授权码>",
  "MAIL_FROM_NAME": "LinMinHao Chat",
  "ADMIN_USER": "admin",
  "ADMIN_PASSWORD": "<强密码>",
  "CORS_ORIGIN": "https://<你的域名>",
  "ALIBABA_ACCESS_KEY_ID": "",
  "ALIBABA_ACCESS_KEY_SECRET": "",
  "SMS_SIGN_NAME": "",
  "SMS_TEMPLATE_CODE": "",
  "DM_ACCOUNT_NAME": "",
  "DM_FROM_ALIAS": "LinMinHao Chat"
}
```

## 变量说明

| 变量 | 必填 | 说明 |
|------|------|------|
| NODE_ENV | 是 | `production` 时启用 HSTS 与生产日志级别 |
| PORT / BIND_HOST | 是 | 监听 127.0.0.1:3000(仅内网) |
| DATA_ROOT | 是 | 数据根目录(Windows `C:\opt\linminhao`;Linux `/opt/linminhao`) |
| VERIFY_CHANNEL | 是 | 短信通道:`alibaba`(阿里云 SMS)或 `dev`(验证码写 logs/dev-otp.log) |
| MAIL_CHANNEL | 是 | 邮件通道:`smtp`(通用 SMTP,如 foxmail/QQ)| `directmail`(阿里云)| `dev`(日志) |
| MAIL_SMTP_HOST / MAIL_SMTP_PORT | smtp 时 | 如 `smtp.foxmail.com:465` / `smtp.qq.com:465` |
| MAIL_USER / MAIL_PASS | smtp 时 | 发信邮箱 + **授权码**(不是邮箱密码;授权码在邮箱设置里开启 SMTP 服务生成) |
| MAIL_FROM_NAME | 否 | 发件人显示名,默认 LinMinHao Chat |
| ADMIN_USER / ADMIN_PASSWORD | 是 | 管理员凭据;不配置时首启自动生成随机密码(admin.cred) |
| CORS_ORIGIN | 是 | 允许的跨域源,固定本站 |
| ALIBABA_ACCESS_KEY_ID / _SECRET | alibaba 时 | RAM 子账号,最小权限(短信+邮件) |
| SMS_SIGN_NAME / SMS_TEMPLATE_CODE | alibaba 时 | 短信签名与模板(控制台审核通过后) |
| DM_ACCOUNT_NAME | alibaba 时 | DirectMail 发信地址(需先验证域名+创建地址) |
| DM_FROM_ALIAS | 否 | 发件人别名 |

## 自动生成的密钥文件(data/config/)

| 文件 | 说明 |
|------|------|
| jwt.secret | JWT 签名密钥(32B base64url,首启生成) |
| otp.pepper | 验证码 HMAC pepper(独立密钥) |
| admin.cred | 自动生成的管理员明文密码(如未手动配置) |

以上文件 0600,不进入 Git。

## 阿里云配置步骤(需用户控制台操作)

1. 创建 RAM 子账号,授予:
   - `AliyunDysmsFullAccess`(短信)
   - `AliyunDirectMailFullAccess`(邮件)
   生成 AccessKey,填入 env.json
2. 短信服务:申请签名(如「LinMinHao」)与验证码模板(变量 `${code}`),等审核
3. DirectMail:验证发信域名(给 your-domain.example 加 TXT 记录,可在同一 DNS 控制台完成),创建发信地址
4. `VERIFY_CHANNEL=alibaba`,重启服务
5. 验证:手机/邮箱收码测试;日志中仅见脱敏目标

## 安全约定

- 所有真实密钥只放服务器 env.json,聊天窗口不传
- `.env`/`config/env.json` 在 .gitignore 中,严禁提交
- 轮换:修改 env.json 后 `schtasks /End /TN lmh-chat && schtasks /Run /TN lmh-chat`
