$ErrorActionPreference = 'Continue'
# 注册全部计划任务(服务由 Task Scheduler 托管,不受 SSH 会话影响)
Write-Output '=== register tasks ==='
schtasks /Create /F /TN "lmh-chat" /TR "C:\opt\linminhao\start-chat.cmd" /SC ONSTART /RU SYSTEM /RL HIGHEST | Out-Null
Write-Output 'lmh-chat (node onstart) registered'
schtasks /Create /F /TN "lmh-nginx" /TR "C:\nginx\nginx.exe" /SC ONSTART /RU SYSTEM | Out-Null
Write-Output 'lmh-nginx (onstart) registered'
schtasks /Create /F /TN "lmh-watchdog" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\watchdog.ps1" /SC MINUTE /RU SYSTEM | Out-Null
Write-Output 'lmh-watchdog (every minute) registered'
schtasks /Create /F /TN "lmh-backup" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\backup.ps1" /SC DAILY /ST 03:00 /RU SYSTEM | Out-Null
Write-Output 'lmh-backup (daily 03:00) registered'
schtasks /Create /F /TN "lmh-logclean" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\opt\linminhao\log-clean.ps1" /SC WEEKLY /D MON /ST 04:30 /RU SYSTEM | Out-Null
Write-Output 'lmh-logclean (weekly) registered'

Write-Output '=== start services now (schtasks run = detached from ssh) ==='
schtasks /Run /TN "lmh-nginx" | Out-Null
schtasks /Run /TN "lmh-chat" | Out-Null
Start-Sleep -Seconds 5
Write-Output '=== verify ==='
$n = Get-Process nginx -ErrorAction SilentlyContinue
Write-Output ("nginx procs: " + $n.Count)
$nd = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*dist*index.js*' }
Write-Output ("node procs: " + $nd.Count)
Start-Sleep -Seconds 2
try {
    $h = Invoke-WebRequest -Uri 'http://127.0.0.1/healthz' -UseBasicParsing -TimeoutSec 8
    Write-Output ("healthz: " + $h.Content)
} catch { Write-Output ("healthz FAILED: " + $_.Exception.Message) }
try {
    $home = Invoke-WebRequest -Uri 'http://127.0.0.1/' -UseBasicParsing -TimeoutSec 8
    Write-Output ("static: HTTP " + $home.StatusCode + " len=" + $home.RawContentLength)
} catch { Write-Output ("static FAILED: " + $_.Exception.Message) }
Write-Output '=== DONE ==='
