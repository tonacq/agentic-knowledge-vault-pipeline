<#
.SYNOPSIS
Syncs this vault's config/working/wiki state with its Google Drive remote via rclone.
Direction is explicit: -Direction Pull (before a run) or -Direction Push (after a run).

.DESCRIPTION
Ported directly from the proven production pattern (run_nate_herk_weekly.sh on the
Oracle VM): Google Drive is the durable canonical store; the vault directory on the
host is treated as a working copy that is pulled fresh before each run and pushed
back after a successful run. This is what makes the VM itself disposable/rebuildable.

Excludes the vault's own copied-in scripts folder from sync (scripts are agent-owned,
not vault data) — mirrors the proven --exclude "/scripts/*_linux.ps1" flag.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [Parameter(Mandatory = $true)][ValidateSet('Pull', 'Push')][string]$Direction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if (-not $config.drive_remote -or -not $config.drive_path) {
    Write-Host "No drive_remote/drive_path configured for this vault; skipping sync."
    return
}

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Warning "rclone not found on PATH; skipping sync (this is expected in a build/test sandbox)."
    return
}

$remote = "$($config.drive_remote):$($config.drive_path)"

if ($Direction -eq 'Pull') {
    Write-Host "Pulling vault state from $remote ..."
    & rclone sync $remote $VaultRoot --exclude '/config/prompts/**' --progress
} else {
    Write-Host "Pushing vault state to $remote ..."
    & rclone copy $VaultRoot $remote --exclude '/config/prompts/**' --progress
}
