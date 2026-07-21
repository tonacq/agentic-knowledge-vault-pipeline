[CmdletBinding()]
param([Parameter(Mandatory)][string]$VaultRoot, [switch]$SkipClaude)

$ErrorActionPreference = 'Stop'
$VaultRoot = [IO.Path]::GetFullPath($VaultRoot)
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$config = Get-Content -Raw (Join-Path $VaultRoot 'config/vault.json') | ConvertFrom-Json
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $VaultRoot "logs/scheduled_$stamp.log"
New-Item -ItemType Directory -Force (Split-Path -Parent $logPath) | Out-Null

function Send-Telegram([string]$Text) {
    if (!$env:TELEGRAM_BOT_TOKEN -or !$env:TELEGRAM_CHAT_ID) { return }
    try {
        Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$env:TELEGRAM_BOT_TOKEN/sendMessage" -Body @{ chat_id=$env:TELEGRAM_CHAT_ID; text=$Text } | Out-Null
    } catch { Write-Warning "Telegram notification failed: $($_.Exception.Message)" }
}

try {
    if ($config.drive_remote -and $config.drive_path) {
        & rclone sync "$($config.drive_remote):$($config.drive_path)" $VaultRoot --exclude 'raw/**' --exclude 'data/clean_transcripts/**' 2>&1 | Tee-Object -FilePath $logPath -Append
        if ($LASTEXITCODE) { throw 'Google Drive pre-run sync failed.' }
    }
    & pwsh -NoProfile -File (Join-Path $root 'scripts/Run-WeeklyPipeline.ps1') -VaultRoot $VaultRoot -SkipClaude:$SkipClaude 2>&1 | Tee-Object -FilePath $logPath -Append
    if ($LASTEXITCODE) { throw 'Weekly pipeline failed.' }
    if ($config.drive_remote -and $config.drive_path) {
        & rclone sync $VaultRoot "$($config.drive_remote):$($config.drive_path)" --exclude 'raw/**' --exclude 'data/clean_transcripts/**' 2>&1 | Tee-Object -FilePath $logPath -Append
        if ($LASTEXITCODE) { throw 'Google Drive post-run sync failed.' }
    }
    Send-Telegram "Wiki Agent Factory: completed $(Split-Path $VaultRoot -Leaf) at $(Get-Date -Format 'yyyy-MM-dd HH:mm')."
} catch {
    $_ | Out-String | Tee-Object -FilePath $logPath -Append | Write-Error
    Send-Telegram "Wiki Agent Factory: FAILED $(Split-Path $VaultRoot -Leaf). See $logPath."
    exit 1
}
