$ErrorActionPreference = "Continue"
# CI deploy for LinMinHaoChat node server (Windows ECS)
# Flow: backup -> extract to staging + verify -> kill app node -> swap in -> start -> health
# Rollback: on health failure, restore the pre-deploy backup automatically.
# Pure ASCII (PowerShell 5.1 reads BOM-less files as ANSI/GBK).
$app  = "C:\opt\linminhao\app"
$dist = "$app\dist"
$node = "C:\tools\node\node.exe"
$ts   = Get-Date -Format "yyyyMMddHHmmss"

function AppNodePids {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like "*linminhao\app\dist\index.js*" }
}

# 1. Backup current dist (reading is fine while node holds the files open)
$bak = "$app\__dist-backup-$ts"
robocopy $dist $bak /E /NFL /NDL /NJH /NJS /np | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Output "BACKUP_FAIL=$LASTEXITCODE"; exit 1 }
Write-Output "BACKUP=$bak"
Get-ChildItem $app -Directory -Filter "__dist-backup-*" | Sort-Object Name -Descending |
  Select-Object -Skip 3 | ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Write-Output ("PRUNED=" + $_.Name) }

# 2. Extract to staging; tarball top-level is "dist/" -> strip it. Fallback: plain extract (old bsdtar).
if (-not (Test-Path "$app\dist.tgz")) { Write-Output "TARBALL_MISSING"; exit 1 }
$stg = "$app\__staging-$ts"
New-Item -ItemType Directory -Path $stg | Out-Null
tar -xzf "$app\dist.tgz" -C $stg --strip-components=1 2>&1 | Out-Null
$src = $stg
if (-not (Test-Path "$stg\index.js")) {
  tar -xzf "$app\dist.tgz" -C $stg 2>&1 | Out-Null
  if (Test-Path "$stg\dist\index.js") { $src = "$stg\dist"; Write-Output "STRIP_UNSUPPORTED_FALLBACK_USED" }
}
if (-not (Test-Path "$src\index.js")) { Write-Output "STAGING_EXTRACT_FAIL"; exit 1 }
Write-Output "STAGING_OK src=$src"

# 3. Syntax-check entry points BEFORE touching the running install
foreach ($f in @("$src\index.js","$src\app.js","$src\ws.js","$src\db.js")) {
  if (-not (Test-Path $f)) { Write-Output "MISSING=$f"; exit 1 }
  & $node --check $f 2>&1 | Out-String | Write-Output
  if ($LASTEXITCODE -ne 0) { Write-Output "SYNTAX_FAIL=$f"; exit 1 }
}
Write-Output "SYNTAX_OK"

function SwapIn {
  foreach ($p in (AppNodePids)) { Stop-Process -Id $p.ProcessId -Force; Write-Output ("KILLED=" + $p.ProcessId) }
  if (-not (AppNodePids)) { Write-Output "NO_APP_NODE_WAS_RUNNING" }
  Remove-Item "$dist\*" -Recurse -Force
  Move-Item "$src\*" $dist -Force
  $env:NODE_ENV = "production"
  Start-Process -FilePath $node -ArgumentList "dist\index.js" -WorkingDirectory $app -WindowStyle Hidden
  Start-Sleep -Seconds 3
}

function Restore {
  foreach ($p in (AppNodePids)) { Stop-Process -Id $p.ProcessId -Force }
  Start-Sleep -Seconds 2
  robocopy $bak $dist /MIR /E /NFL /NDL /NJH /NJS /np | Out-Null
  $env:NODE_ENV = "production"
  Start-Process -FilePath $node -ArgumentList "dist\index.js" -WorkingDirectory $app -WindowStyle Hidden
  Write-Output "RESTORED_FROM_BACKUP=$bak"
}

# 4. Swap + start
SwapIn
Write-Output "SWAP_DONE"

# 5. Health wait (up to ~90s; the lmh-watchdog scheduled task is a backstop)
$ok = $false; $h = ""
for ($i = 0; $i -lt 9; $i++) {
  Start-Sleep -Seconds 10
  try { $h = curl.exe --noproxy * -s -m 5 http://127.0.0.1:3000/api/health 2>$null } catch { $h = "" }
  if ("$h" -match '"ok":true') { $ok = $true; break }
}
if ($ok) {
  Remove-Item "$stg" -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item "$app\dist.tgz" -Force -ErrorAction SilentlyContinue
  Write-Output "DEPLOY_OK $h"
  exit 0
}

# 6. Roll back to the pre-deploy backup and report
Restore
Remove-Item "$stg" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$app\dist.tgz" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 8
$h2 = ""
try { $h2 = curl.exe --noproxy * -s -m 5 http://127.0.0.1:3000/api/health 2>$null } catch { }
Write-Output "HEALTH_FAIL RESTORED health=$h2"
exit 1
