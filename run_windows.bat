@echo off
setlocal
set "PATH=C:\flutter\bin;%PATH%"

echo ========================================================
echo   SideAssistant Windows Runner
echo ========================================================
echo.

cd /d "%~dp0"

set "SOURCE_DIR=%~dp0build\windows\x64\runner\Debug"
if "%~1"=="--bin" goto run_binary
if "%~1"=="-b" goto run_binary
goto build

:run_binary
if exist "build\windows\x64\runner\Release\side_assistant.exe" (
    set "SOURCE_DIR=%~dp0build\windows\x64\runner\Release"
    goto stage
)
if exist "build\windows\x64\runner\Debug\side_assistant.exe" (
    goto stage
)
echo [WARN] No prebuilt executable found. Building Windows application...

:build
where flutter >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Flutter SDK not found in PATH or C:\flutter\bin.
    echo Please make sure Flutter is properly installed.
    echo.
    pause
    exit /b 1
)

echo [INFO] Building SideAssistant on Windows...
echo.
call flutter build windows --debug
if errorlevel 1 goto failed

:stage
rem Run a deployed copy: a Low-integrity workspace image cannot save AppData.
powershell.exe -NoProfile -File "%~dp0tool\stage_windows_app.ps1" -SourceDirectory "%SOURCE_DIR%" -ResultFile "%~dp0.dart_tool\windows_runtime_path.txt"
if errorlevel 1 goto failed
set /p DEPLOYED_EXE=<"%~dp0.dart_tool\windows_runtime_path.txt"
for %%I in ("%DEPLOYED_EXE%") do set "DEPLOYED_DIR=%%~dpI"
echo [INFO] Starting deployed application...
start "" /D "%DEPLOYED_DIR%" "%DEPLOYED_EXE%"
exit /b %errorlevel%

:failed
echo [ERROR] Windows build or deployment failed.
pause
exit /b 1
