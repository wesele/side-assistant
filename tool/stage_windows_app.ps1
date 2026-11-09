param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'side_assistant.exe'))) {
    throw 'The Windows build does not contain side_assistant.exe.'
}
if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'data/flutter_assets'))) {
    throw 'The Windows build does not contain its Flutter assets.'
}
if (-not $env:LOCALAPPDATA) {
    throw 'LOCALAPPDATA is unavailable; cannot deploy the Windows application.'
}

# Copy code/assets into the normal per-user Programs directory. New files
# inherit its security metadata instead of the workspace's Low integrity
# label. Do not alter ACLs or copy/reset any user configuration.
$manifest = (Get-ChildItem -LiteralPath $sourcePath -File -Recurse |
    Sort-Object FullName | ForEach-Object {
        '{0}|{1}|{2}' -f $_.FullName.Substring($sourcePath.Length), $_.Length, $_.LastWriteTimeUtc.Ticks
    }) -join "`n"
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifest))).Replace('-', '').Substring(0, 16)
} finally {
    $hasher.Dispose()
}
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'Programs/SideAssistant'
$runtimeDirectory = Join-Path $runtimeRoot ('runtime-' + $digest)
$readyFile = Join-Path $runtimeDirectory '.package-ready'
if (-not (Test-Path -LiteralPath $readyFile)) {
    # Preserve any existing incomplete directory rather than overwriting it.
    if (Test-Path -LiteralPath $runtimeDirectory) {
        $runtimeDirectory += '-' + [Guid]::NewGuid().ToString('N')
        $readyFile = Join-Path $runtimeDirectory '.package-ready'
    }
    New-Item -ItemType Directory -Path $runtimeDirectory | Out-Null
    Get-ChildItem -LiteralPath $sourcePath -Force |
        Copy-Item -Destination $runtimeDirectory -Recurse
    [IO.File]::WriteAllText($readyFile, $digest, [Text.UTF8Encoding]::new($false))
}
$executable = Join-Path $runtimeDirectory 'side_assistant.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    throw 'The deployed application is incomplete.'
}
$resultPath = [IO.Path]::GetFullPath($ResultFile)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resultPath)) | Out-Null
[IO.File]::WriteAllText($resultPath, $executable, [Text.UTF8Encoding]::new($false))
Write-Output $executable
