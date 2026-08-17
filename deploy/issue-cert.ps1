# Issue LetsEncrypt cert via win-acme HTTP-01 (run AFTER DNS A record is live)
# ASCII only for PowerShell 5.1 compatibility
$ErrorActionPreference = 'Continue'
$wacs = 'C:\tools\win-acme\wacs.exe'
$email = Read-Host 'LE contact email (replace with yours)'
$hosts = Read-Host 'Domain (e.g. chat.example.com,www.chat.example.com)'
$webroot = 'C:\opt\linminhao\acme'
$certDir = 'C:\nginx\certs'

New-Item -ItemType Directory -Force $certDir | Out-Null

Write-Output '=== issuing certificate ==='
& $wacs --accepttos --email $email --target manual --host $hosts --webroot $webroot --installation manual --certificatestore no --pemfilespath $certDir 2>&1 | Select-Object -Last 15

Write-Output '=== cert files ==='
Get-ChildItem $certDir | Select-Object Name, Length
if (Test-Path "$certDir\fullchain.pem") {
    Write-Output 'CERT OK'
} else {
    Write-Output 'CERT MISSING - check DNS A record is live and port 80 reachable from internet'
}
