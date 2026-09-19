@echo off
REM 只跑数据层，把额度 JSON 打印出来（不启动界面）
setlocal
where node >nul 2>nul
if not %errorlevel%==0 (
    echo [run] 未找到 node，请先安装 Node.js 18+。
    exit /b 1
)
node "%~dp0resources\fetch-quota.mjs" --pretty
