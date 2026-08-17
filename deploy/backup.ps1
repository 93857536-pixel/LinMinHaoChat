# LinMinHao Chat daily backup (ASCII only)
$ErrorActionPreference = 'Continue'
$root = 'C:\opt\linminhao'
$backupDir = "$root\backups"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = "$backupDir\chat-backup-$stamp.zip"
$retain = 14

Write-Output "=== Backup $stamp ==="

# 1. copy db (wal checkpoint safe enough)
$db = "$root\db\chat.db"
$dbCopy = "$env:TEMP\chat-db-copy.db"
if (Test-Path $db) {
    Copy-Item $db $dbCopy -Force
    Write-Output "db copied"
} else {
    Write-Output "db not found: $db"
}

# 2. pack: db + messages + attachments + env.json
$tempDir = "$env:TEMP\lmh-backup-$stamp"
New-Item -ItemType Directory -Force "$tempDir\data" | Out-Null
if (Test-Path $dbCopy) { Move-Item $dbCopy "$tempDir\data\chat.db" -Force }
if (Test-Path "$root\messages") { Copy-Item -Recurse "$root\messages" "$tempDir\data\" }
if (Test-Path "$root\attachments") { Copy-Item -Recurse "$root\attachments" "$tempDir\data\" }
if (Test-Path "$root\config\env.json") { Copy-Item "$root\config\env.json" "$tempDir\" }

Compress-Archive -Path "$tempDir\*" -DestinationPath $target -Force
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

# 3. retain last N
Get-ChildItem $backupDir -Filter 'chat-backup-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $retain | Remove-Item -Force -ErrorAction SilentlyContinue

# 4. report
$size = if (Test-Path $target) { [math]::Round((Get-Item $target).Length / 1MB, 2) } else { 0 }
Write-Output "backup done: $target ($size MB)"
Write-Output ("retained backups: " + (Get-ChildItem $backupDir -Filter 'chat-backup-*.zip' | Measure-Object).Count)
