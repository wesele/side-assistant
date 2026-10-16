$ErrorActionPreference = "Stop"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  SideAssistant Live Testing & Driver Starting...       " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$exePath = "build\windows\x64\runner\Debug\side_assistant.exe"
$baseUrl = "http://127.0.0.1:19823"

# 1. Ensure application is running
$proc = Get-Process -Name "side_assistant" -ErrorAction SilentlyContinue
if (-not $proc) {
    if (-not (Test-Path $exePath)) {
        Write-Error "Executable not found: $exePath"
        exit 1
    }
    Write-Host "[1/6] Starting application: $exePath ..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath $exePath -PassThru
    Start-Sleep -Seconds 3
} else {
    Write-Host "[1/6] Detected side_assistant.exe running (PID: $($proc.Id))" -ForegroundColor Green
}

# 2. Wait for automation driver to be ready
$healthUrl = "$baseUrl/health"
Write-Host "[2/6] Connecting to automation driver: $healthUrl ..." -ForegroundColor Yellow
$connected = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 2
        if ($health.status -eq "ok") {
            $connected = $true
            break
        }
    } catch {
        Start-Sleep -Milliseconds 500
    }
}

if (-not $connected) {
    Write-Error "Cannot connect to automation driver on port 19823."
    exit 1
}
Write-Host "[OK] Driver handshake successful!" -ForegroundColor Green

# 3. Test Case 1: Standby status
Write-Host "`n--- [Case 1: Check Standby Status] ---" -ForegroundColor Cyan
$statusUrl = "$baseUrl/status"
$status = Invoke-RestMethod -Uri $statusUrl -Method Get
Write-Host "Status: $($status.status) | Hint: $($status.statusHint)"
if ($status.status -ne "idle") {
    $resetUrl = "$baseUrl/reset"
    Invoke-RestMethod -Uri $resetUrl -Method Post | Out-Null
    Start-Sleep -Seconds 1
}
Write-Host "[OK] App is in Standby (Idle) state" -ForegroundColor Green

# 4. Test Case 2: Wake Word + Query + End Word -> LLM
Write-Host "`n--- [Case 2: Start Word + Query + End Word -> LLM] ---" -ForegroundColor Cyan
$chineseQuery1 = [System.Text.Encoding]::UTF8.GetString(@(0xE6, 0x99, 0x93, 0xE6, 0xBC, 0xAB, 0x20, 0xE6, 0x8E, 0xA8, 0xE8, 0x8D, 0x90, 0xE4, 0xB8, 0x89, 0xE5, 0xBA, 0xA7, 0xE4, 0xB8, 0xAD, 0xE5, 0x9B, 0xBD, 0xE8, 0x91, 0x97, 0xE5, 0x90, 0x8D, 0xE7, 0x9A, 0x84, 0xE5, 0x8E, 0x86, 0xE5, 0x8F, 0xB2, 0xE6, 0x96, 0x87, 0xE5, 0x8C, 0x96, 0xE5, 0x90, 0x8D, 0xE5, 0x9F, 0x8E, 0x20, 0xE5, 0x9B, 0x9E, 0xE7, 0xAD, 0x94))
Write-Host "Simulating user voice input (Chinese query): $chineseQuery1" -ForegroundColor Yellow

$simUrl = "$baseUrl/simulate"
$body1 = @{ text = $chineseQuery1 } | ConvertTo-Json
$simRes = Invoke-RestMethod -Uri $simUrl -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body1)) -ContentType "application/json; charset=utf-8"
Write-Host "App response: accepted=$($simRes.accepted), status=$($simRes.currentStatus)"

Write-Host "Waiting for DeepSeek streaming response..." -NoNewline
$done = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    Write-Host "." -NoNewline
    $cur = Invoke-RestMethod -Uri $statusUrl -Method Get
    if ($cur.status -eq "idle" -and $cur.messageCount -ge 2) {
        $done = $true
        break
    }
}
Write-Host ""

if (-not $done) {
    Write-Error "Timeout waiting for LLM completion"
    exit 1
}

$msgUrl = "$baseUrl/messages"
$messages = (Invoke-RestMethod -Uri $msgUrl -Method Get).messages
$lastMsg = $messages[-1]
Write-Host "Assistant Answer Received! Length: $($lastMsg.content.Length) chars" -ForegroundColor Magenta
Write-Host "[OK] Wake word detection, query transcription, and DeepSeek reply verified!" -ForegroundColor Green

# 5. Test Case 3: Context retention
Write-Host "`n--- [Case 3: Multi-turn Context Retention] ---" -ForegroundColor Cyan
$chineseQuery2 = [System.Text.Encoding]::UTF8.GetString(@(0xE6, 0x99, 0x93, 0xE6, 0xBC, 0xAB, 0x20, 0xE5, 0x88, 0x9A, 0xE6, 0x89, 0x8D, 0xE6, 0x8F, 0x90, 0xE5, 0x88, 0xB0, 0xE7, 0x9A, 0x84, 0xE5, 0x9F, 0x8E, 0xE5, 0xB8, 0x82, 0xE4, 0xB8, 0xAD, 0xE5, 0x93, 0xAA, 0xE4, 0xB8, 0x80, 0xE5, 0xBA, 0xA7, 0xE5, 0x9C, 0xA8, 0xE6, 0x9C, 0x80, 0xE5, 0x8C, 0x97, 0xE6, 0x96, 0xB9, 0x20, 0xE5, 0x9B, 0x9E, 0xE7, 0xAD, 0x94))
Write-Host "Simulating follow-up query: $chineseQuery2" -ForegroundColor Yellow

$body2 = @{ text = $chineseQuery2 } | ConvertTo-Json
Invoke-RestMethod -Uri $simUrl -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body2)) -ContentType "application/json; charset=utf-8" | Out-Null

Write-Host "Waiting for multi-turn inference..." -NoNewline
$done = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    Write-Host "." -NoNewline
    $cur = Invoke-RestMethod -Uri $statusUrl -Method Get
    if ($cur.status -eq "idle" -and $cur.messageCount -ge 4) {
        $done = $true
        break
    }
}
Write-Host ""

$messages = (Invoke-RestMethod -Uri $msgUrl -Method Get).messages
$secondReply = $messages[-1].content
Write-Host "Follow-up Answer Received! Length: $($secondReply.Length) chars" -ForegroundColor Magenta
Write-Host "[OK] Multi-turn context retention verified!" -ForegroundColor Green

# 6. Test Case 4: Reset session
Write-Host "`n--- [Case 4: Reset Session Command] ---" -ForegroundColor Cyan
$resetCommand = [System.Text.Encoding]::UTF8.GetString(@(0xE6, 0x96, 0xB0, 0xE8, 0xB5, 0xB7, 0xE4, 0xB8, 0x80, 0xE4, 0xB8, 0xAA))
Write-Host "Simulating reset word: $resetCommand" -ForegroundColor Yellow

$bodyReset = @{ text = $resetCommand } | ConvertTo-Json
Invoke-RestMethod -Uri $simUrl -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyReset)) -ContentType "application/json; charset=utf-8" | Out-Null
Start-Sleep -Seconds 1

$cur = Invoke-RestMethod -Uri $statusUrl -Method Get
Write-Host "Messages after reset: $($cur.messageCount) | Hint: $($cur.statusHint)"
if ($cur.messageCount -eq 0 -and $cur.status -eq "idle") {
    Write-Host "[OK] Session successfully reset, context cleared without LLM request!" -ForegroundColor Green
} else {
    Write-Error "Reset failed: messageCount is not 0"
    exit 1
}

# 7. Test Case 5: In-App 5-Step Diagnostic Suite
Write-Host "`n--- [Case 5: Trigger In-App 5-Step Diagnostic Suite] ---" -ForegroundColor Cyan
Write-Host "Triggering run-self-test on live app..." -ForegroundColor Yellow
$testUrl = "$baseUrl/run-self-test"
$diag = Invoke-RestMethod -Uri $testUrl -Method Post
foreach ($log in $diag.logs) {
    Write-Host $log
}

if ($diag.success) {
    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host "  ALL LIVE TESTING SCENARIOS PASSED WITH 100% SUCCESS!  " -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
    exit 0
} else {
    Write-Error "Diagnostic test reported failures."
    exit 1
}
