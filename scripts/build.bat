@echo off
setlocal

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..

echo === Building Fantom LSP Server ===
cd /d "%ROOT_DIR%\server"
call fan build.fan
if errorlevel 1 goto :error

echo === Building VS Code Client ===
cd /d "%ROOT_DIR%\client"
call npm install
call npm run compile
if errorlevel 1 goto :error

echo === Build complete ===
goto :eof

:error
echo Build failed!
exit /b 1
