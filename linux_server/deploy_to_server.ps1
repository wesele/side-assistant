param(
    [string]$ServerHost = "192.168.31.233",
    [string]$User = "hao",
    [string]$IdentityFile = "c:\wh\233",
    [string]$RemoteDir = "/home/hao/side_assistant",
    [string]$RemoteDataDir = "/home/hao/.local/share/side_assistant",
    [switch]$FullInstall
)

$ErrorActionPreference = "Stop"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$sshArgs = @(
    "-n",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "ConnectTimeout=10",
    "-l", $User,
    "-i", $IdentityFile,
    $ServerHost
)

$scpArgs = @(
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "ConnectTimeout=10",
    "-i", $IdentityFile
)

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SideAssistant Deploy -> ${User}@${ServerHost}" -ForegroundColor Cyan
Write-Host "  Remote Code Dir: $RemoteDir" -ForegroundColor Cyan
Write-Host "  Remote Data Dir (PROTECTED): $RemoteDataDir" -ForegroundColor Cyan
Write-Host "  Mode: $(if ($FullInstall) { 'Full Install' } else { 'Fast Incremental (Code Update)' })" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ------------------------------------------------------------
# [安全第一防线] 部署前强制备份远端配置与用户数据
# ------------------------------------------------------------
Write-Host "[0/4] [Safety Guard] Backing up remote preferences.json..." -ForegroundColor Yellow

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$remoteBackupCmd = "[ -s $RemoteDataDir/preferences.json ] && cp -p $RemoteDataDir/preferences.json $RemoteDataDir/preferences.json.bak_$timestamp && echo 'BACKED_UP' || echo 'NO_PREFS'"
$backupStatus = & ssh @sshArgs $remoteBackupCmd

if ($backupStatus -match 'BACKED_UP') {
    Write-Host "  [OK] Remote backup created on 233: preferences.json.bak_$timestamp" -ForegroundColor Green
    
    # 额外在本地也存一份镜像副本，确保即使服务器磁盘异常也有底可查
    $localBackupDir = "$PSScriptRoot\..\build\remote_backups"
    if (!(Test-Path $localBackupDir)) {
        New-Item -ItemType Directory -Force -Path $localBackupDir | Out-Null
    }
    $localBackupFile = "$localBackupDir\preferences_233_$timestamp.json"
    try {
        & scp @scpArgs "${User}@${ServerHost}:${RemoteDataDir}/preferences.json" "$localBackupFile"
        Write-Host "  [OK] Local backup snapshot saved: $localBackupFile" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Failed to pull local copy of preferences.json, remote backup exists." -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  [INFO] No existing preferences.json found on server to back up." -ForegroundColor Gray
}

# 记录重启前 preferences.json 的大小
$remoteSizeBefore = (& ssh @sshArgs "[ -f $RemoteDataDir/preferences.json ] && stat -c %s $RemoteDataDir/preferences.json || echo '0'").Trim()

# ------------------------------------------------------------
# 1. Compile Dart Kernel
# ------------------------------------------------------------
Write-Host "[1/4] Compiling Dart Kernel (build/linux_server.dill)..." -ForegroundColor Cyan
dart compile kernel bin/linux_server.dart -o build/linux_server.dill

# ------------------------------------------------------------
# 2. Upload updated code (严禁目标指向 $RemoteDataDir)
# ------------------------------------------------------------
Write-Host "[2/4] Uploading updated kernel and scripts to $RemoteDir..." -ForegroundColor Cyan
& ssh @sshArgs "mkdir -p $RemoteDir/linux_server $RemoteDir/assets/scripts"
& scp @scpArgs build/linux_server.dill "${User}@${ServerHost}:${RemoteDir}/linux_server.dill"
& scp @scpArgs linux_server/install.sh linux_server/run_server.sh linux_server/52-disable-suspend.lua "${User}@${ServerHost}:${RemoteDir}/linux_server/"
& scp @scpArgs assets/scripts/edge_tts_worker.py "${User}@${ServerHost}:${RemoteDir}/assets/scripts/edge_tts_worker.py"

if ($FullInstall) {
    Write-Host "  [Full Mode] Syncing libraries and models..." -ForegroundColor Yellow
    $sherpaLinuxDir = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\sherpa_onnx_linux-1.13.8\linux\x64"
    if (Test-Path $sherpaLinuxDir) {
        & scp @scpArgs "$sherpaLinuxDir\libonnxruntime.so" "$sherpaLinuxDir\libsherpa-onnx-c-api.so" "$sherpaLinuxDir\libsherpa-onnx-cxx-api.so" "${User}@${ServerHost}:${RemoteDir}/lib/"
    }
    & scp @scpArgs assets/models/silero_vad.onnx "${User}@${ServerHost}:${RemoteDir}/assets/models/"
    & scp @scpArgs assets/models/sense-voice/model.int8.onnx assets/models/sense-voice/tokens.txt "${User}@${ServerHost}:${RemoteDir}/assets/models/sense-voice/"
    & scp @scpArgs assets/models/streaming-zipformer/* "${User}@${ServerHost}:${RemoteDir}/assets/models/streaming-zipformer/"
    if (Test-Path "assets/models/speaker/*") {
        & scp @scpArgs assets/models/speaker/* "${User}@${ServerHost}:${RemoteDir}/assets/models/speaker/"
    }
    Write-Host "  [Full Mode] Running install.sh on server..." -ForegroundColor Yellow
    & ssh @sshArgs "sed -i 's/\r$//' $RemoteDir/linux_server/*.sh && chmod +x $RemoteDir/linux_server/*.sh && bash $RemoteDir/linux_server/install.sh"
} else {
    Write-Host "[3/4] Fast compiling native binary and restarting service on 233..." -ForegroundColor Cyan
    $remoteCmd = "sed -i 's/\r$//' $RemoteDir/linux_server/*.sh && chmod +x $RemoteDir/linux_server/*.sh && " +
                 "export PATH=/home/$User/.local/share/side_assistant/dart-sdk/bin:`$PATH && " +
                 "dart compile exe $RemoteDir/linux_server.dill -o $RemoteDir/side_assistant_server.new && " +
                 "chmod +x $RemoteDir/side_assistant_server.new && " +
                 "mv -f $RemoteDir/side_assistant_server.new $RemoteDir/side_assistant_server && " +
                 "sudo systemctl restart side-assistant.service"
    & ssh @sshArgs $remoteCmd
}

# ------------------------------------------------------------
# 4. [安全第二防线] 重启后校验配置完整性
# ------------------------------------------------------------
Write-Host "[4/4] [Safety Guard] Verifying remote preferences.json integrity after restart..." -ForegroundColor Yellow
Start-Sleep -Seconds 2

$remoteSizeAfter = (& ssh @sshArgs "[ -f $RemoteDataDir/preferences.json ] && stat -c %s $RemoteDataDir/preferences.json || echo '0'").Trim()

if ([int64]$remoteSizeBefore -gt 0 -and [int64]$remoteSizeAfter -eq 0) {
    Write-Host "  [CRITICAL ALERT] preferences.json became empty! Restoring from backup..." -ForegroundColor Red
    & ssh @sshArgs "cp -p $RemoteDataDir/preferences.json.bak_$timestamp $RemoteDataDir/preferences.json && sudo systemctl restart side-assistant.service"
    Write-Host "  [RECOVERED] Successfully restored preferences.json from backup!" -ForegroundColor Green
} else {
    Write-Host "  [OK] Data integrity check passed (size: $remoteSizeAfter bytes)." -ForegroundColor Green
}

$sw.Stop()
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Deploy completed safely in $($sw.Elapsed.TotalSeconds.ToString('0.0')) seconds!" -ForegroundColor Green
Write-Host "  Service URL: http://${ServerHost}:19823" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
