# 部署指南(DEPLOYMENT)

生产环境:阿里云 ECS(Windows Server 2025 Datacenter,1C2G)+ 域名 your-domain.example(阿里云 DNS)

## 架构选型说明

资源受限(2GB RAM)且无 Docker,采用轻量原生栈:
Node.js(原生 Windows)+ SQLite + Nginx for Windows + win-acme(Let's Encrypt)。

## 目录布局(服务器)

```
C:\tools\node\            Node.js 22(解压版)
C:\nginx\                 Nginx for Windows(配置 + 证书)
C:\opt\linminhao\
  app\                    后端代码(server 源码 + dist)
  web\dist\               前端构建产物(nginx 静态托管)
  db\chat.db              SQLite(WAL)
  messages\YYYY\MM\DD\    消息密文文件 *.enc
  attachments\YYYY\MM\DD\ 附件密文文件 *.enc
  backups\                每日备份 zip(保留 14 份)
  logs\                   应用日志(14/30 天轮转)
  config\env.json         生产配置(0600,含凭据)
  start-chat.cmd          服务启动脚本
  watchdog.ps1            进程守护
  backup.ps1              备份
  log-clean.ps1           日志清理
```

## 首次部署步骤(已执行,供复现)

1. 安装运行时:
   - Node 22:npmmirror 下载 win-x64 zip 解压到 `C:\tools\node`
   - Nginx:nginx.org 下载解压到 `C:\nginx`
2. 上传代码:server 源码 → `app\`;web 构建产物 → `web\dist\`
3. 安装依赖(国内镜像 + prebuilt):
   ```powershell
   cd C:\opt\linminhao\app
   npm config set registry https://registry.npmmirror.com
   npm install --ignore-scripts --no-audit --no-fund
   # better-sqlite3 手动放置 prebuilt(npmmirror 镜像)到 node_modules/better-sqlite3/build/Release/
   npm run build
   ```
   > 注意:Windows 无 Python/VS 时禁止 node-gyp 编译,必须用 prebuilt 二进制
4. 配置:`config\env.json`(见 ENVIRONMENT.md),`icacls` 收紧权限
5. Nginx:conf\nginx.conf 反代 + 静态托管 + WS(见 deploy/nginx.conf)
6. 证书:win-acme 签发(见「HTTPS 启用」)
7. 进程托管:
   ```powershell
   schtasks /Create /F /TN lmh-chat    /TR "C:\opt\linminhao\start-chat.cmd" /SC ONSTART /RU SYSTEM /RL HIGHEST
   schtasks /Create /F /TN lmh-nginx   /TR "cmd /c cd /d C:\nginx && C:\nginx\nginx.exe" /SC ONSTART /RU SYSTEM
   schtasks /Create /F /TN lmh-watchdog /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\watchdog.ps1" /SC MINUTE /RU SYSTEM
   schtasks /Create /F /TN lmh-backup   /TR "powershell ... backup.ps1" /SC DAILY /ST 03:00 /RU SYSTEM
   schtasks /Create /F /TN lmh-logclean /TR "powershell ... log-clean.ps1" /SC WEEKLY /D MON /ST 04:30 /RU SYSTEM
   ```
   > 关键:SSH 会话内 Start-Process 的子进程会在会话结束时被杀,必须用 schtasks(独立于会话)

## HTTPS 启用(依赖 DNS)

前置:在你域名服务商的 DNS 控制台为 `你的域名` / `www.你的域名` 添加 A 记录 → `你的服务器公网IP`

1. 签发(HTTP-01,80 端口已反代到 ACME webroot):
   ```powershell
   C:\tools\win-acme\wacs.exe --accepttos --email <你的邮箱> ^
     --target manual --host "你的域名,www.你的域名" ^
     --webroot C:\opt\linminhao\acme --installation manual ^
     --certificatestore no --pemfilespath C:\nginx\certs
   ```
   (deploy/issue-cert.ps1 已封装)
2. 切换:运行 deploy/enable-https.ps1(写入 443 + HSTS + 跳转配置并 reload)
3. 续期:win-acme 计划任务(建议每日一次 `wacs.exe --renew --quiet`,证书 90 天自动续)

## 更新流程

```powershell
# 后端
scp server 源码 → C:\opt\linminhao\app
cd C:\opt\linminhao\app && npm install && npm run build
schtasks /End /TN lmh-chat && schtasks /Run /TN lmh-chat   # 或等 watchdog 拉起
# 前端
scp web/dist → C:\opt\linminhao\web\dist(nginx 直接生效)
```

## 回滚

- 代码:git 回退 → 重新构建 → 重启服务
- 数据:从 `backups\chat-backup-*.zip` 解压恢复 `db\chat.db`、`messages\`、`attachments\`
- 证书:win-acme 上一份证书在 `C:\tools\win-acme\certs` 内有归档

## 健康检查

- `GET /healthz` → `{"ok":true,"db":true,...}`(公网可达)
- `GET /api/health` 同上
- watchdog.log 记录自动拉起事件
