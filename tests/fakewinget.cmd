@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fakewinget.ps1" %*
exit /b %ERRORLEVEL%
