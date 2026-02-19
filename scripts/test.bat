@echo off
setlocal enabledelayedexpansion

echo === Building fantomLsp pod ===
cd /d "%~dp0..\server"
if errorlevel 1 exit /b 1

call fan build.fan
if errorlevel 1 exit /b 1

echo.
echo === Running all tests ===
echo.

call fan fantomLsp::HoverProviderTest
if errorlevel 1 exit /b 1

call fan fantomLsp::CompletionProviderTest
if errorlevel 1 exit /b 1

call fan fantomLsp::SignatureHelpProviderTest
if errorlevel 1 exit /b 1

call fan fantomLsp::JsonRpcTest
if errorlevel 1 exit /b 1

call fan fantomLsp::LspMessagesTest
if errorlevel 1 exit /b 1

call fan fantomLsp::SerializationTest
if errorlevel 1 exit /b 1

call fan fantomLsp::ParserTest
if errorlevel 1 exit /b 1

call fan fantomLsp::TextDocumentManagerTest
if errorlevel 1 exit /b 1

call fan fantomLsp::LspUtilsTest
if errorlevel 1 exit /b 1

echo.
echo === All tests passed ===
