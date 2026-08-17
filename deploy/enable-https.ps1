# Switch nginx from HTTP to HTTPS + WSS (after cert issued)
# ASCII only
$ErrorActionPreference = 'Continue'

$httpsConf = @'
worker_processes  1;
error_log  logs/error.log  warn;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    client_max_body_size 12m;
    server_tokens  off;
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 80;
        server_name your-domain.example www.your-domain.example;
        location ^~ /.well-known/acme-challenge/ {
            root C:/opt/linminhao/acme;
        }
        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 443 ssl;
        http2 on;
        server_name your-domain.example www.your-domain.example;

        ssl_certificate     C:/nginx/certs/fullchain.pem;
        ssl_certificate_key C:/nginx/certs/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;
        add_header Referrer-Policy no-referrer always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' wss://your-domain.example; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" always;

        root C:/opt/linminhao/web/dist;
        index index.html;
        location / {
            try_files $uri $uri/ /index.html;
        }
        location ~* \.(js|css|png|jpg|jpeg|gif|svg|ico|webp|woff2?)$ {
            expires 7d;
            add_header Cache-Control "public, immutable";
        }

        location /api/ {
            proxy_pass http://127.0.0.1:3000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_connect_timeout 10s;
            proxy_read_timeout 60s;
        }

        location /ws {
            proxy_pass http://127.0.0.1:3000;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }

        location = /healthz {
            proxy_pass http://127.0.0.1:3000/api/health;
        }
    }
}
'@

Set-Content -Path C:\nginx\conf\nginx.conf -Value $httpsConf -Encoding ASCII
Push-Location C:\nginx
C:\nginx\nginx.exe -t 2>&1
$t = $LASTEXITCODE
if ($t -eq 0) {
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Start-Process -FilePath C:\nginx\nginx.exe -WorkingDirectory C:\nginx -WindowStyle Hidden
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest -Uri 'https://your-domain.example/healthz' -UseBasicParsing -TimeoutSec 10
        Write-Output ("HTTPS healthz: HTTP " + $r.StatusCode + " " + $r.Content)
    } catch { Write-Output ("HTTPS check FAILED: " + $_.Exception.Message) }
    try {
        $h = Invoke-WebRequest -Uri 'http://your-domain.example/' -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction SilentlyContinue
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 301) { Write-Output 'HTTP->HTTPS redirect: 301 OK' }
        else { Write-Output 'HTTP->HTTPS redirect check: see above' }
    }
} else {
    Write-Output 'nginx config test FAILED, not restarting'
}
Pop-Location
Write-Output '=== DONE ==='
