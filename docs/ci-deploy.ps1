$ErrorActionPreference = "Continue"
# CI deploy: backup + extract + syntax check + restart + health (Windows ECS)
# Caller: scp dist.tgz to C:\opt\linminhao\app\dist.tgz, then run this script.
$app  = "C:\opt\linminhao\app"
$dist = "$app\dist"
$ts   = Get-Date -Format "yyyyMMddHHmmss"

# --- 1. Backup current dist into dist\__bak-<ts> (robocopy excludes self dir) ---
$bak = "$dist\__bak-$ts"
robocopy $dist $bak /E /XD $bak /NFL /NDL /NJH /NJS /np | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Output "BACKUP_FAIL=$LASTEXITCODE"; exit 1 }
Write-Output "BACKUP=$bak"

# Prune: keep 3 newest backups
Get-ChildItem $dist -Directory -Filter "__bak-*" | Sort-Object Name -Descending |
  Select-Object -Skip 3 | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force
    Write-Output "PRUNED=$($_.Name)"
  }

# --- 2. Extract new dist (overwrite) ---
if (-not (Test-Path "$app\dist.tgz")) { Write-Output "TARBALL_MISSING"; exit 1 }
tar -xzf "$app\dist.tgz" -C $dist
if (-not (Test-Path "$dist\index.js")) { Write-Output "EXTRACT_FAIL"; exit 1 }
Write-Output "EXTRACT_OK"

# --- 3. Syntax check entry points ---
foreach ($f in @("$dist\index.js","$dist\app.js","$dist\ws.js","$dist\db.js")) {
  if (-not (Test-Path $f)) { Write-Output "MISSING=$f"; exit 1 }
  & "C:\tools\node\node.exe" --check $f 2>&1 | Out-String | Write-Output
  if ($LASTEXITCODE -ne 0) { Write-Output "SYNTAX_FAIL=$f"; exit 1 }
}
Write-Output "SYNTAX_OK"

# --- 4. Restart: kill only THIS app's node; lmh-watchdog (60s) restarts it ---
$p = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
     Where-Object { $_.CommandLine -like "*linminhao\app\dist\index.js*" }
foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force; Write-Output "KILLED=$($x.ProcessId)" }
if (-not $p) { Write-Output "NO_NODE_RUNNING" }

# --- 5. Wait for health (up to 120s) ---
$ok = $false; $h = ""
for ($i = 0; $i -lt 12; $i++) {
  Start-Sleep -Seconds 10
  try { $h = curl.exe --noproxy * -s -m 5 http://127.0.0.1:3000/api/health 2>$null } catch { $h = "" }
  if ("$h" -match '"ok":true') { $ok = $true; break }
}
if ($ok) { Write-Output "DEPLOY_OK $h"; exit 0 }
Write-Output "HEALTH_FAIL"
exit 1
