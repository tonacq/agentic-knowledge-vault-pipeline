<#
.SYNOPSIS
Backs up exactly one vault (config, working state, wiki content) to its archive/ folder
and optionally to the remote configured in config/vault.json -> backup.

.DESCRIPTION
Vault-scoped by design (ADR-003 / ADR-004): a vault must be able to be backed up,
restored, or moved without needing anything from the shared agent/ tree beyond this
script itself.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (-not $config.backup -or -not $config.backup.enabled) {
    Write-Host "Backup disabled for this vault."
    return
}

$vaultName = Split-Path -Leaf $VaultRoot
$archiveDir = Join-Path $VaultRoot 'archive'
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupName = "${vaultName}_backup_${stamp}.zip"
$backupPath = Join-Path $archiveDir $backupName

# Stage into a temp directory that mirrors the desired archive layout, so
# working/manifest.csv lands at working/manifest.csv inside the zip - not flattened to the
# zip root the way passing the bare file path to Compress-Archive would produce - without
# pulling in the rest of working/ (raw downloads, clean transcripts, batches).
$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "vault-backup-staging-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
try {
    foreach ($dir in @('config', 'wiki')) {
        $src = Join-Path $VaultRoot $dir
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stagingDir $dir) -Recurse
        }
    }

    $manifestSrc = Join-Path $VaultRoot 'working/manifest.csv'
    if (Test-Path -LiteralPath $manifestSrc) {
        $stagedWorking = Join-Path $stagingDir 'working'
        New-Item -ItemType Directory -Force -Path $stagedWorking | Out-Null
        Copy-Item -LiteralPath $manifestSrc -Destination (Join-Path $stagedWorking 'manifest.csv')
    }

    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $backupPath -Force
} finally {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Retention: keep only the newest N per config.backup.keep
$keep = if ($config.backup.keep) { [int]$config.backup.keep } else { 12 }
Get-ChildItem -LiteralPath $archiveDir -Filter "${vaultName}_backup_*.zip" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keep |
    Remove-Item -Force

if ($config.backup.remote -and $config.backup.destination) {
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        & rclone copy $backupPath "$($config.backup.remote):$($config.backup.destination)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "rclone copy failed for backup destination $($config.backup.remote):$($config.backup.destination) (exit code $LASTEXITCODE)"
        }
        Write-Host "Backup synced to $($config.backup.remote):$($config.backup.destination)"
    } else {
        Write-Warning "rclone not found on PATH; local backup only ($backupPath)."
    }
}

Write-Host "Backup complete: $backupPath"
