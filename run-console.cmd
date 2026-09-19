@echo off
REM 直接以调试模式运行挂件（保留控制台输出，便于看报错）
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resources\widget.ps1" -Console
