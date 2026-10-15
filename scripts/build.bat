@echo off
setlocal

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..

echo === Building Fantom LSP Server ===
cd /d "%ROOT_DIR%\server"
call fan build.fan
if errorlevel 1 goto :error

echo === Copying pod to client\server\ ===
if not exist "%ROOT_DIR%\client\server\lib\fan" mkdir "%ROOT_DIR%\client\server\lib\fan"
copy /Y "%ROOT_DIR%\server\lib\fan\fantomLsp.pod" "%ROOT_DIR%\client\server\lib\fan\fantomLsp.pod"
if errorlevel 1 goto :error
echo Copied fantomLsp.pod to client\server\lib\fan\

echo === Building VS Code Client ===
cd /d "%ROOT_DIR%\client"
call npm install
call npm run compile
if errorlevel 1 goto :error

echo === Packaging VSIX ===
copy /Y "%ROOT_DIR%\README.md" "%ROOT_DIR%\client\README.md"
copy /Y "%ROOT_DIR%\CHANGELOG.md" "%ROOT_DIR%\client\CHANGELOG.md"
copy /Y "%ROOT_DIR%\LICENSE" "%ROOT_DIR%\client\LICENSE"

cd /d "%ROOT_DIR%\client"
    call npx --yes @vscode/vsce package --allow-missing-repository
if errorlevel 1 (
    del /Q README.md CHANGELOG.md LICENSE 2>nul
    goto :error
)

del /Q README.md CHANGELOG.md LICENSE 2>nul

echo === Build complete ===
for %%f in ("%ROOT_DIR%\client\*.vsix") do echo VSIX: %%f
goto :eof

:error
echo Build failed!
exit /b 1
