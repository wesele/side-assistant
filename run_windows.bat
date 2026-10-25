@echo off
setlocal
set "PATH=C:\flutter\bin;%PATH%"

echo ========================================================
echo   SideAssistant Windows Runner
echo ========================================================
echo.

cd /d "%~dp0"

if "%~1"=="--bin" goto run_binary
if "%~1"=="-b" goto run_binary
goto run_flutter

:run_binary
if exist "build\windows\x64\runner\Release\side_assistant.exe" (
    echo [INFO] Launching prebuilt Release executable...
    start "" "build\windows\x64\runner\Release\side_assistant.exe"
    exit /b 0
)
if exist "build\windows\x64\runner\Debug\side_assistant.exe" (
    echo [INFO] Launching prebuilt Debug executable...
    start "" "build\windows\x64\runner\Debug\side_assistant.exe"
    exit /b 0
)
echo [WARN] No prebuilt executable found. Falling back to flutter run...
echo.

:run_flutter
where flutter >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Flutter SDK not found in PATH or C:\flutter\bin.
    echo Please make sure Flutter is properly installed.
    echo.
    pause
    exit /b 1
)

echo [INFO] Starting SideAssistant on Windows via Flutter...
echo.
flutter run -d windows %*

if %errorlevel% neq 0 (
    echo.
    echo [INFO] Application exited or failed to start (code: %errorlevel%).
    pause
)
