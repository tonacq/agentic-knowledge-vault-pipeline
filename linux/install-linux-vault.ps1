[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultRoot,
    [switch]$SkipDependencyCheck
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name. See docs/INSTALL.md."
    }
}

if (-not $SkipDependencyCheck) {
    foreach ($command in @("yt-dlp")) { Require-Command $command }
}

$VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
foreach ($relative in @(
    "config", "data", "data/clean_transcripts", "raw", "wiki/sources",
    "wiki/concepts", "wiki/tools", "wiki/workflows", "prompts", "reports",
    "logs", "scripts"
)) {
    New-Item -ItemType Directory -Path (Join-Path $VaultRoot $relative) -Force | Out-Null
}

$manifest = Join-Path $VaultRoot "data/manifest.csv"
if (-not (Test-Path -LiteralPath $manifest)) {
    Set-Content -LiteralPath $manifest -Encoding UTF8 -Value (
        "video_id,title,url,channel,upload_date,transcript_file,transcript_status," +
        "ingest_status,date_discovered,date_downloaded,date_ingested,last_checked," +
        "notes,clean_status,clean_transcript_file,source_status,source_file," +
        "source_created,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch"
    )
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Copy-Item -LiteralPath (Join-Path $repoRoot "CLAUDE.md") -Destination (Join-Path $VaultRoot "CLAUDE.md") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "config/vault.example.json") -Destination (Join-Path $VaultRoot "config/vault.example.json") -Force
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "scripts") -Filter "*_linux.ps1" -File |
    Copy-Item -Destination (Join-Path $VaultRoot "scripts") -Force

Write-Host "Linux vault initialised: $VaultRoot" -ForegroundColor Green
Write-Host "Next: copy config/vault.example.json to config/vault.json, edit it, then run scripts/run_weekly_agentic_pipeline_v2_linux.ps1."
