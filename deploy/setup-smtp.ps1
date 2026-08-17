# Secure SMTP credential setup - run this ONCE on the server (via Aliyun Workbench)
# Password input is masked. Credentials go into config\env.json (0600), never chat.
# ASCII only
$ErrorActionPreference = 'Stop'
$envFile = 'C:\opt\linminhao\config\env.json'

Write-Output '=== LinMinHao Chat SMTP 邮件通道配置 ==='
Write-Output '本脚本把 SMTP 凭证安全写入 config\env.json(不回显、不进聊天窗口)'
Write-Output ''

$host = Read-Host 'SMTP 服务器 (foxmail 填 smtp.foxmail.com,QQ 邮箱填 smtp.qq.com)'
$port = Read-Host '端口 (SSL 465 / STARTTLS 587,默认 465)'
if ($port -eq '') { $port = '465' }
$user = Read-Host 'SMTP 账号 (发信邮箱完整地址,如 you@example.com)'
$pass = Read-Host 'SMTP 授权码 (不是邮箱密码!)' -AsSecureString
$fromName = Read-Host '发件人显示名 (回车默认 LinMinHao Chat)'
if ($fromName -eq '') { $fromName = 'LinMinHao Chat' }

if ($host -eq '' -or $user -eq '') { Write-Output 'ERROR: 服务器/账号必填'; exit 1 }
$plainPass = [System.Net.NetworkCredential]::new('', $pass).Password
if ($plainPass -eq '') { Write-Output 'ERROR: 授权码不能为空'; exit 1 }

$env = @{}
if (Test-Path $envFile) { $env = Get-Content $envFile -Raw | ConvertFrom-Json }
$env.MAIL_CHANNEL = 'smtp'
$env.MAIL_SMTP_HOST = $host
$env.MAIL_SMTP_PORT = $port
$env.MAIL_USER = $user
$env.MAIL_PASS = $plainPass
$env.MAIL_FROM_NAME = $fromName

$env | ConvertTo-Json | Set-Content $envFile -Encoding UTF8
icacls $envFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

Write-Output ''
Write-Output '=== 配置已写入 config\env.json,重启服务生效 ==='
Write-Output '重启: schtasks /End /TN lmh-chat && schtasks /Run /TN lmh-chat'
