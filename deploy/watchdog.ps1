# LinMinHao Chat watchdog (ASCII only)
$node = 'C:\tools\node\node.exe'
$nginx = 'C:\nginx\nginx.exe'
$app = 'C:\opt\linminhao\app\dist\index.js'
$work = 'C:\opt\linminhao\app'
$logFile = 'C:\opt\linminhao\logs\watchdog.log'
try {
    $env:NODE_ENV = 'production'
    $env:DATA_ROOT = 'C:\opt\linminhao'
    # node check
    $nodeUp = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*dist*index.js*' }
    if (-not $nodeUp) {
        Start-Process -FilePath $node -ArgumentList $app -WorkingDirectory $work -WindowStyle Hidden
        Add-Content $logFile "$(Get-Date -Format s) node restarted"
    }
    # nginx check
    $nginxUp = Get-CimInstance Win32_Process -Filter "Name='nginx.exe'"
    if (-not $nginxUp) {
        Start-Process -FilePath $nginx -WorkingDirectory 'C:\nginx' -WindowStyle Hidden
        Add-Content $logFile "$(Get-Date -Format s) nginx restarted"
    }
} catch {
    Add-Content $logFile "$(Get-Date -Format s) ERROR $_"
}
