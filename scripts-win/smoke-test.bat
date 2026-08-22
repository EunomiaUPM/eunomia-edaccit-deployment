@echo off
REM smoke-test.bat - check ESRILab connectivity and the token flow.
REM Launches the .ps1 next to it bypassing the machine ExecutionPolicy, which
REM is Restricted by default on Windows Server and would refuse to run it.
REM Arguments are forwarded, e.g.  deploy-mini.bat -NoMapViewer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0smoke-test.ps1" %*
exit /b %ERRORLEVEL%
