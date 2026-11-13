# Probe CF DNS records + cloudflared + current root content. NO secrets printed.
$ErrorActionPreference = 'Continue'
$raw = [System.IO.File]::ReadAllText('C:\opt\linminhao\config\cf-api.json')
$cfg = $raw | ConvertFrom-Json
$zone = $cfg.zone_id
$token = $cfg.api_token
Write-Output ("zone_id present: " + [bool]$zone + "  api_token present: " + [bool]$token)
Write-Output ""
# CF DNS records via direct curl (bypass any proxy)
$out = & curl.exe --noproxy "*" -s -m 25 -H ("Authorization: Bearer " + $token) ("https://api.cloudflare.com/client/v4/zones/" + $zone + "/dns_records?per_page=100")
try {
  $recs = $out | ConvertFrom-Json
  if ($recs.success -eq $true) {
    Write-Output "=== CF DNS RECORDS (name / type / content / proxied) ==="
    foreach ($r in $recs.result) {
      Write-Output ("{0}  {1}  {2}  proxied={3}" -f $r.name, $r.type, $r.content, $r.proxy_status)
    }
  } else {
    Write-Output ("CF API error status=" + $recs.status + " msg=" + $recs.errors[0].message)
  }
} catch {
  Write-Output ("CF DNS query failed: " + $_.Exception.Message + " | head=" + $out.Substring(0, [Math]::Min(160,$out.Length)))
}
Write-Output ""
Write-Output "=== CLOUDFLARED SERVICE STATE ==="
sc.exe query Cloudflared 2>$null | Select-String 'STATE'
Write-Output ""
Write-Output "=== CURRENT web/dist/index.html (title) ==="
$idx = [System.IO.File]::ReadAllText('C:\opt\linminhao\web\dist\index.html')
if ($idx -match '<title>(.*?)</title>') { Write-Output ("title: " + $Matches[1]) } else { Write-Output "(no title tag; first 120 chars:) " + $idx.Substring(0, [Math]::Min(120,$idx.Length)) }
Write-Output ""
Write-Output "=== official-site dir check ==="
foreach ($d in @('C:\opt\linminhao\site','C:\opt\linminhao\official','C:\opt\linminhao\website')) {
  if (Test-Path $d) { Write-Output ("EXISTS: " + $d) } else { Write-Output ("missing: " + $d) }
}
