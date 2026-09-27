@echo off
setlocal
"%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0pause-codex-vm.ps1" %*
exit /b %ERRORLEVEL%
