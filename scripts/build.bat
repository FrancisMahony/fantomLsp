@echo off
setlocal

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..

echo === Building Fantom LSP Server ===
cd /d "%ROOT_DIR%\server"
call fan build.fan
if errorlevel 1 goto :error

echo === Copying pod to client\server\ ===
if "%FAN_HOME%"=="" (echo ERROR: FAN_HOME not set & exit /b 1)
if not exist "%ROOT_DIR%\client\server\lib\fan" mkdir "%ROOT_DIR%\client\server\lib\fan"
copy /Y "%FAN_HOME%\lib\fan\fantomLsp.pod" "%ROOT_DIR%\client\server\lib\fan\fantomLsp.pod"
if errorlevel 1 goto :error
echo Copied fantomLsp.pod to client\server\lib\fan\

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
