@echo off
chcp 65001 >nul
set "ANDROID_HOME=C:\Android\sdk"
set "ANDROID_SDK_ROOT=C:\Android\sdk"
set "PATH=C:\Android\sdk\emulator;C:\Android\sdk\platform-tools;C:\flutter\bin;%PATH%"

echo ========================================================
echo   SideAssistant Android 启动器 (Idioma_API31)
echo ========================================================
echo.
echo [1/3] 正在启动 Android 模拟器...
start "" /d "C:\Android\sdk\emulator" "C:\Android\sdk\emulator\emulator.exe" -avd Idioma_API31 -no-snapshot-load

echo.
echo [2/3] 等待模拟器连接并完成启动...
C:\Android\sdk\platform-tools\adb.exe wait-for-device
:wait_boot
for /f "delims=" %%i in ('C:\Android\sdk\platform-tools\adb.exe shell getprop sys.boot_completed 2^>nul') do set BOOT=%%i
if not "%BOOT%"=="1" (
    timeout /t 2 /nobreak >nul
    goto wait_boot
)

echo.
echo [3/3] 模拟器已就绪！正在编译并启动 SideAssistant...
echo.
cd /d "%~dp0"
flutter run -d emulator-5554
