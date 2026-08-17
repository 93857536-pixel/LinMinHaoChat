@echo off
cd /d C:\opt\linminhao\app
set NODE_ENV=production
set DATA_ROOT=C:\opt\linminhao
C:\tools\node\node.exe dist\index.js >> C:\opt\linminhao\logs\app.out.log 2>&1
