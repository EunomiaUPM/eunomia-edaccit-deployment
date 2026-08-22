@echo off
REM teardown-mini.bat - remove every trace of the mini deployment.
REM Launches the .ps1 next to it bypassing the machine ExecutionPolicy, which
REM is Restricted by default on Windows Server and would refuse to run it.
REM Arguments are forwarded, e.g.  deploy-mini.bat -NoMapViewer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0teardown-mini.ps1" %*
exit /b %ERRORLEVEL%
