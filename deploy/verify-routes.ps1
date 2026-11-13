# Verify post-deploy routing. ASCII only.
$ErrorActionPreference = 'Continue'
function Probe($url, $name) {
  $c = & curl.exe --noproxy "*" -s -m 20 -o "C:\temp\v_$name.out" -w "%{http_code}" $url
  $size = if (Test-Path "C:\temp\v_$name.out") { (Get-Item "C:\temp\v_$name.out").Length } else { 0 }
  Write-Output ("{0} -> HTTP {1} ({2} bytes)" -f $name, $c, $size)
}
Probe "https://linminhao.top/" "root"
Probe "https://chat.linminhao.top/" "chat"
Probe "https://linminhao.top/api/health" "root_api"
Probe "https://chat.linminhao.top/api/health" "chat_api"
Probe "https://linminhao.top/healthz" "root_healthz"
Probe "https://www.linminhao.top/" "www"

Write-Output ""
Write-Output "=== root / content markers ==="
$root = Get-Content "C:\temp\v_root.out" -Raw
if ($root -match '<title>(.*?)</title>') { Write-Output ("root title: " + $Matches[1]) }
if ($root -match 'linminhao -official|site\.css') { Write-Output "root IS official site (site.css found)" }
else { Write-Output "root title: " + (($root -split "`n")[0..2] -join ' | ').Substring(0, [Math]::Min(120, 200)) }

Write-Output "=== chat / content markers ==="
$chat = Get-Content "C:\temp\v_chat.out" -Raw
if ($chat -match '<title>(.*?)</title>') { Write-Output ("chat title: " + $Matches[1]) }
if ($chat -match 'assets/index') { Write-Output "chat IS LinMinHaoChat SPA (index-*.js found)" }

Write-Output "=== www location header ==="
$wwwHdr = & curl.exe --noproxy "*" -s -m 20 -I "https://www.linminhao.top/"
($wwwHdr | Select-String -Pattern 'HTTP|location') -join ""

Write-Output "=== root /api/health body ==="
Get-Content "C:\temp\v_root_api.out" -Raw
