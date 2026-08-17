# LinMinHao Chat — 进程守护与自启动
# 1) 注册计划任务:开机启动 node 服务 + nginx
# 2) 注册计划任务:每分钟 watchdog,进程消失自动拉起
$ErrorActionPreference = 'Stop'

$node = 'C:\tools\node\node.exe'
$appDir = 'C:\opt\linminhao\app'
$nginx = 'C:\nginx\nginx.exe'
$env:NODE_ENV = 'production'
$env:DATA_ROOT = 'C:\opt\linminhao'

Write-Output '=== 1. 启动脚本 ==='
@'
@echo off
cd /d C:\opt\linminhao\app
set NODE_ENV=production
set DATA_ROOT=C:\opt\linminhao
C:\tools\node\node.exe dist\index.js >> C:\opt\linminhao\logs\app.out.log 2>&1
'@ | Set-Content -Path C:\opt\linminhao\start-chat.cmd -Encoding ASCII

Write-Output '=== 2. 注册自启动任务(开机) ==='
schtasks /Create /F /TN "lmh-chat" /TR "C:\opt\linminhao\start-chat.cmd" /SC ONSTART /RU SYSTEM /RL HIGHEST | Out-Null
Write-Output 'lmh-chat task created'

# nginx 服务化:使用 nginx 自带 windows service 辅助脚本?nginx for windows 无服务支持,
# 用计划任务 + watchdog 实现
schtasks /Create /F /TN "lmh-nginx" /TR "C:\nginx\nginx.exe" /SC ONSTART /RU SYSTEM | Out-Null
Write-Output 'lmh-nginx task created'

Write-Output '=== 3. watchdog ==='
@'
$node = 'C:\tools\node\node.exe'
$nginx = 'C:\nginx\nginx.exe'
$app = 'C:\opt\linminhao\app\dist\index.js'
$work = 'C:\opt\linminhao\app'
try {
    $env:NODE_ENV = 'production'
    $env:DATA_ROOT = 'C:\opt\linminhao'
    # node 服务检查
    $nodeUp = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*dist\index.js*' }
    if (-not $nodeUp) {
        Start-Process -FilePath $node -ArgumentList $app -WorkingDirectory $work -WindowStyle Hidden
        Add-Content C:\opt\linminhao\logs\watchdog.log "$(Get-Date -Format s) node restarted"
    }
    # nginx 检查
    $nginxUp = Get-CimInstance Win32_Process -Filter "Name='nginx.exe'" | Where-Object { $_.CommandLine -like '*nginx.exe' }
    if (-not $nginxUp) {
        Start-Process -FilePath $nginx -WorkingDirectory 'C:\nginx' -WindowStyle Hidden
        Add-Content C:\opt\linminhao\logs\watchdog.log "$(Get-Date -Format s) nginx restarted"
    }
} catch {
    Add-Content C:\opt\linminhao\logs\watchdog.log "$(Get-Date -Format s) ERROR $_"
}
'@ | Set-Content -Path C:\opt\linminhao\watchdog.ps1 -Encoding UTF8

schtasks /Create /F /TN "lmh-watchdog" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\watchdog.ps1" /SC MINUTE /RU SYSTEM | Out-Null
Write-Output 'lmh-watchdog task created (every minute)'

Write-Output '=== 4. 备份任务(每日 03:00) ==='
schtasks /Create /F /TN "lmh-backup" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\backup.ps1" /SC DAILY /ST 03:00 /RU SYSTEM | Out-Null
Write-Output 'lmh-backup task created (daily 03:00)'

Write-Output '=== 5. 日志轮转清理(每周) ==='
@'
$logDir = 'C:\opt\linminhao\logs'
Get-ChildItem $logDir -Filter 'app.*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $logDir -Filter 'error.*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
'@ | Set-Content -Path C:\opt\linminhao\log-clean.ps1 -Encoding UTF8
schtasks /Create /F /TN "lmh-logclean" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\log-clean.ps1" /SC WEEKLY /D MON /ST 04:30 /RU SYSTEM | Out-Null
Write-Output 'lmh-logclean task created'

Write-Output '=== DONE ==='
schtasks /Query /TN "lmh-chat" | Out-Null
schtasks /Query /TN "lmh-nginx" | Out-Null
schtasks /Query /TN "lmh-watchdog" | Out-Null
schtasks /Query /TN "lmh-backup" | Out-Null
Write-Output 'all tasks registered'
