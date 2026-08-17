# LinMinHao Chat log cleaner (ASCII only)
$logDir = 'C:\opt\linminhao\logs'
Get-ChildItem $logDir -Filter 'app.*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $logDir -Filter 'error.*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
