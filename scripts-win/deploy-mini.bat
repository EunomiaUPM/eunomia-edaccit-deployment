@echo off
REM deploy-mini.bat - bring up the whole mini deployment and onboard it.
REM Launches the .ps1 next to it bypassing the machine ExecutionPolicy, which
REM is Restricted by default on Windows Server and would refuse to run it.
REM Arguments are forwarded, e.g.  deploy-mini.bat -NoMapViewer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-mini.ps1" %*
exit /b %ERRORLEVEL%
