# 备份与恢复(BACKUP)

## 策略

- 频率:每日 03:00(计划任务 `lmh-backup`)
- 内容:`db\chat.db` + `messages\`(密文)+ `attachments\`(密文)+ `config\env.json`
- 格式:`backups\chat-backup-YYYYMMDD-HHmmss.zip`
- 保留:最近 14 份,自动清理更旧
- 位置:本地磁盘(建议定期下载到本机/OSS;密文本就是密文,传输可走任何通道)

## 备份内容为何仍是密文

E2EE 在客户端完成,服务器所有持久化数据(DB 元数据 + .enc 密文)本就是密文。
备份不会引入任何明文副本 —— 不存在"备份导致明文泄露"的路径。

## 手动备份

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\backup.ps1
```

## 恢复流程

1. 停服务:`schtasks /End /TN lmh-chat`(watchdog 会在 1 分钟内拉起,恢复期间可临时禁用 `lmh-watchdog` 或改 start-chat.cmd)
2. 解压目标备份 zip 到临时目录
3. 覆盖:
   - `db\chat.db` ← zip 内 `data\chat.db`
   - `messages\` ← zip 内 `data\messages\`
   - `attachments\` ← zip 内 `data\attachments\`
   - `config\env.json`(如需回滚配置)
4. 启动:`schtasks /Run /TN lmh-chat`
5. 验证:`GET /healthz` 返回 db:true;抽查一条消息能解密(用原客户端)

## 备份验证

部署时已实测:zip 生成成功、保留计数正确、zip 内不含明文(E2EE 验收脚本扫描)。

## 异地备份建议

- 将 `backups\` 目录同步到阿里云 OSS(内网流量免费)或下载到本机
- 若启用 OSS 生命周期规则,建议保留 30 天
