[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultRoot,
    [switch]$SkipDependencyCheck
)

$ErrorActionPreference = 'Stop'

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name. See docs/INSTALL.md."
    }
}

if (-not $SkipDependencyCheck) {
    foreach ($command in @('yt-dlp', 'rclone')) { Require-Command $command }
}

$VaultRoot = [IO.Path]::GetFullPath($VaultRoot)
foreach ($relative in @('config', 'data', 'data/clean_transcripts', 'raw', 'wiki/sources', 'wiki/concepts', 'wiki/tools', 'wiki/workflows', 'prompts', 'reports', 'logs', 'scripts')) {
    New-Item -ItemType Directory -Path (Join-Path $VaultRoot $relative) -Force | Out-Null
}

$manifest = Join-Path $VaultRoot 'data/manifest.csv'
if (-not (Test-Path -LiteralPath $manifest)) {
    'video_id,title,url,upload_date,transcript_status,clean_status,source_status,synthesis_status,synthesis_batch,synthesis_last_checked,raw_vtt_file,clean_transcript_file,source_file,synthesis_evidence,last_error' | Set-Content -LiteralPath $manifest -Encoding utf8
}

$root = Split-Path -Parent $PSCommandPath
Copy-Item -LiteralPath (Join-Path $root 'CLAUDE.md') -Destination (Join-Path $VaultRoot 'CLAUDE.md') -Force
Copy-Item -LiteralPath (Join-Path $root 'config/vault.example.json') -Destination (Join-Path $VaultRoot 'config/vault.example.json') -Force
Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' | Copy-Item -Destination (Join-Path $VaultRoot 'scripts') -Force

Write-Host "Vault initialised: $VaultRoot" -ForegroundColor Green
Write-Host "Next: copy config/vault.example.json to config/vault.json, edit it, then run scripts/Run-WeeklyPipeline.ps1."
