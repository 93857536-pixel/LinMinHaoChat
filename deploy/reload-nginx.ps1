# ASCII-only: swap nginx config, test, reload via SYSTEM scheduled task.
$ErrorActionPreference = 'Stop'
$conf = 'C:\nginx\conf\nginx.conf'
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
Copy-Item $conf "C:\nginx\conf\nginx.conf.bak-$stamp"
Write-Output "backed up to nginx.conf.bak-$stamp"

# test new config (nginx paths are relative -> must run from C:\nginx)
Push-Location C:\nginx
& C:\nginx\nginx.exe -t -c C:\nginx\conf\nginx.conf
$testErr = $LASTEXITCODE
Pop-Location
if ($testErr -ne 0) {
  Write-Output "CONFIG TEST FAILED - not swapping"
  exit 1
}
Write-Output "config test OK"

# swap in the new config
Copy-Item 'C:\opt\linminhao\nginx.conf.new' $conf -Force
Push-Location C:\nginx
& C:\nginx\nginx.exe -t -c $conf
$swapErr = $LASTEXITCODE
Pop-Location
if ($swapErr -ne 0) {
  Write-Output "SWAP VERIFICATION FAILED - restoring backup"
  Copy-Item "C:\nginx\conf\nginx.conf.bak-$stamp" $conf -Force
  exit 2
}
Write-Output "swapped OK"

# reload: master runs as SYSTEM; use one-shot highest-priv scheduled task
$taskName = "nginx-reload-$stamp"
schtasks /create /tn $taskName /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /tr "cmd /c cd /d C:\nginx && C:\nginx\nginx.exe -s reload" | Out-Null
schtasks /run /tn $taskName | Out-Null
Start-Sleep -Seconds 3
schtasks /delete /tn $taskName /f | Out-Null
Write-Output "reload issued"
