@echo off
REM run-keep-open.bat - stops at STARTED, leaving the dataplane proxy usable.
REM Docker Desktop is the only requirement: no Python, no shell.
REM Extra arguments are forwarded to the test (--dataset, -v, --list-datasets...).
docker compose -f "%~dp0docker-compose.e2e.yaml" run --rm --build e2e --keep-open %*
exit /b %ERRORLEVEL%
