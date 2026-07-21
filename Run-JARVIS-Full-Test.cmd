@echo off
setlocal EnableExtensions

rem Relaunch this file in an Administrator Command Prompt.
if /I not "%~1"=="__ELEVATED__" (
    set "JARVIS_LAUNCHER=%~f0"
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$cmdArgs = @('/d','/c',('""{0}" __ELEVATED__"' -f $env:JARVIS_LAUNCHER)); $process = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdArgs -Verb RunAs -Wait -PassThru; exit $process.ExitCode"
    exit /b %ERRORLEVEL%
)

cd /d "%~dp0"
title JARVIS Full Regression Test Suite

set "OPENWEBUI_API_TOKEN="
set /p "OPENWEBUI_API_TOKEN=Paste the Open WebUI API key, then press Enter: "
if not defined OPENWEBUI_API_TOKEN (
    echo.
    echo No API key was entered.
    exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-tests.ps1"
set "JARVIS_TEST_EXIT=%ERRORLEVEL%"
set "OPENWEBUI_API_TOKEN="
exit /b %JARVIS_TEST_EXIT%
