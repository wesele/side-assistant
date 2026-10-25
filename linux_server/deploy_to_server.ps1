param(
    [string]$ServerHost = "192.168.31.233",
    [string]$User = "hao",
    [string]$IdentityFile = "c:\wh\233",
    [string]$RemoteDir = "/home/hao/side_assistant",
    [switch]$ForceOverwriteConfig
)

$ErrorActionPreference = "Stop"

Write-Host "[1/5] Compiling portable Dart kernel (build/linux_server.dill)..." -ForegroundColor Cyan
dart compile kernel bin/linux_server.dart -o build/linux_server.dill

Write-Host "[2/5] Preparing remote directory structure on ${User}@${ServerHost}:${RemoteDir}..." -ForegroundColor Cyan
ssh -o StrictHostKeyChecking=no $ServerHost -l $User -i $IdentityFile "mkdir -p $RemoteDir/linux_server $RemoteDir/lib/services/speech $RemoteDir/assets/models/sense-voice $RemoteDir/assets/models/streaming-zipformer $RemoteDir/assets/models/hr && rm -f $RemoteDir/side_assistant_server"

Write-Host "[3/5] Uploading server kernel, scripts, Edge-TTS worker, and sherpa-onnx Linux x64 libraries..." -ForegroundColor Cyan
scp -o StrictHostKeyChecking=no -i $IdentityFile `
    build/linux_server.dill `
    "${User}@${ServerHost}:${RemoteDir}/linux_server.dill"

scp -o StrictHostKeyChecking=no -i $IdentityFile `
    linux_server/install.sh `
    "${User}@${ServerHost}:${RemoteDir}/linux_server/"

# run_server.sh 与 side-assistant.service 可能已在服务器上被手动修改，仅在远端不存在时才上传；
# 如需强制覆盖，传入 -ForceOverwriteConfig。
foreach ($f in @("run_server.sh", "side-assistant.service")) {
    $exists = ssh -o StrictHostKeyChecking=no $ServerHost -l $User -i $IdentityFile "[ -f $RemoteDir/linux_server/$f ] && echo YES || echo NO"
    if ($ForceOverwriteConfig -or $exists.Trim() -ne "YES") {
        scp -o StrictHostKeyChecking=no -i $IdentityFile "linux_server/$f" "${User}@${ServerHost}:${RemoteDir}/linux_server/$f"
    } else {
        Write-Host "  Remote $f exists, keeping server copy." -ForegroundColor Gray
    }
}

scp -o StrictHostKeyChecking=no -i $IdentityFile `
    lib/services/speech/edge_tts_worker.py `
    "${User}@${ServerHost}:${RemoteDir}/lib/services/speech/edge_tts_worker.py"

$sherpaLinuxDir = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\sherpa_onnx_linux-1.13.8\linux\x64"
if (Test-Path $sherpaLinuxDir) {
    scp -o StrictHostKeyChecking=no -i $IdentityFile `
        "$sherpaLinuxDir\libonnxruntime.so" `
        "$sherpaLinuxDir\libsherpa-onnx-c-api.so" `
        "$sherpaLinuxDir\libsherpa-onnx-cxx-api.so" `
        "${User}@${ServerHost}:${RemoteDir}/lib/"
}

Write-Host "[4/5] Syncing ASR & VAD models (skipping if already uploaded)..." -ForegroundColor Cyan
$senseVoiceExists = ssh -o StrictHostKeyChecking=no $ServerHost -l $User -i $IdentityFile "[ -s $RemoteDir/assets/models/sense-voice/model.int8.onnx ] && echo YES || echo NO"
if ($senseVoiceExists.Trim() -ne "YES") {
    scp -o StrictHostKeyChecking=no -i $IdentityFile `
        assets/models/silero_vad.onnx `
        "${User}@${ServerHost}:${RemoteDir}/assets/models/"
    scp -o StrictHostKeyChecking=no -i $IdentityFile `
        assets/models/sense-voice/model.int8.onnx `
        assets/models/sense-voice/tokens.txt `
        "${User}@${ServerHost}:${RemoteDir}/assets/models/sense-voice/"
    scp -o StrictHostKeyChecking=no -i $IdentityFile `
        assets/models/streaming-zipformer/encoder-epoch-99-avg-1.int8.onnx `
        assets/models/streaming-zipformer/decoder-epoch-99-avg-1.onnx `
        assets/models/streaming-zipformer/joiner-epoch-99-avg-1.int8.onnx `
        assets/models/streaming-zipformer/tokens.txt `
        "${User}@${ServerHost}:${RemoteDir}/assets/models/streaming-zipformer/"
    if (Test-Path "assets/models/hr/lexicon.txt") {
        scp -o StrictHostKeyChecking=no -i $IdentityFile `
            assets/models/hr/lexicon.txt `
            "${User}@${ServerHost}:${RemoteDir}/assets/models/hr/"
    }
} else {
    Write-Host "  Models already present on remote server, skipping 230MB upload." -ForegroundColor Gray
}

Write-Host "[5/5] Running install.sh on remote server to compile native ELF binary & start systemd service..." -ForegroundColor Cyan
ssh -o StrictHostKeyChecking=no $ServerHost -l $User -i $IdentityFile "sed -i 's/\r$//' $RemoteDir/linux_server/*.sh && chmod +x $RemoteDir/linux_server/*.sh && bash $RemoteDir/linux_server/install.sh"
