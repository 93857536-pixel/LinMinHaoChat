# Retry probes with error detail. ASCII only.
$ErrorActionPreference = 'Continue'
function Probe2($url, $name, $tries) {
  for ($i = 1; $i -le $tries; $i++) {
    $err = & curl.exe --noproxy "*" -s -m 15 -o NUL -w "%{http_code}" $url 2>&1
    Write-Output ("{0} try {1}: HTTP {2}" -f $name, $i, $err)
    if ($err -eq "200" -or $err -eq "301") { return }
    Start-Sleep -Seconds 3
  }
}
Probe2 "https://chat.linminhao.top/" "chat" 5
Probe2 "https://linminhao.top/" "root" 5
Write-Output ""
Write-Output "=== curl error detail for chat ==="
& curl.exe --noproxy "*" -s -m 20 -v https://chat.linminhao.top/ 2>&1 | Select-Object -Last 12
