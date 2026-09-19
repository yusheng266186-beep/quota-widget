@echo off
REM 一键编译 额度挂件 启动器（Release）
setlocal
pushd "%~dp0"

where dotnet >nul 2>nul
if %errorlevel%==0 (
    echo [build] 使用 dotnet build
    dotnet build -c Release
) else (
    echo [build] 未找到 dotnet，尝试 classic MSBuild
    set "MSBUILD=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
    if not exist "%MSBUILD%" set "MSBUILD=%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
    if not exist "%MSBUILD%" (
        echo [build] 找不到 MSBuild，请安装 .NET SDK 或 Visual Studio 2022。
        popd & exit /b 1
    )
    "%MSBUILD%" QuotaWidget.csproj -t:Build -p:Configuration=Release -v:minimal -nologo
)

set "RC=%errorlevel%"
popd
if "%RC%"=="0" (
    echo.
    echo [build] 完成：bin\Release\net48\QuotaWidget.exe
) else (
    echo.
    echo [build] 失败，退出码 %RC%
)
exit /b %RC%
