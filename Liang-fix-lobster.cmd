@echo off
chcp 65001 >nul 2>&1
setlocal
title 龍蝦 AI 修復工具

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%Liang-fix-lobster.ps1"

if not exist "%PS1%" (
    echo.
    echo 找不到修復主程式：
    echo %PS1%
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo 修復工具已結束，代碼：%EXITCODE%
    echo.
    pause
)

endlocal
exit /b %EXITCODE%
