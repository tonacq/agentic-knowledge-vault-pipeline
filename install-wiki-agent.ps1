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
foreach ($relative in @('config', 'data', 'data/clean_transcripts', 'raw', 'wiki/sources', 'wiki/concepts', 'wiki/tools', 'wiki/workflows', 'wiki/synthesis', 'prompts', 'reports', 'logs', 'scripts')) {
    New-Item -ItemType Directory -Path (Join-Path $VaultRoot $relative) -Force | Out-Null
}

$manifest = Join-Path $VaultRoot 'data/manifest.csv'
if (-not (Test-Path -LiteralPath $manifest)) {
    'video_id,title,url,channel,upload_date,transcript_file,transcript_status,ingest_status,date_discovered,date_downloaded,date_ingested,last_checked,notes,clean_status,clean_transcript_file,source_status,source_file,source_created,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch' | Set-Content -LiteralPath $manifest -Encoding utf8
}

$root = Split-Path -Parent $PSCommandPath
Copy-Item -LiteralPath (Join-Path $root 'CLAUDE.md') -Destination (Join-Path $VaultRoot 'CLAUDE.md') -Force
Copy-Item -LiteralPath (Join-Path $root 'config/vault.example.json') -Destination (Join-Path $VaultRoot 'config/vault.example.json') -Force
# Install only compatibility entry points.  The former Update-YoutubeVault.ps1
# is deliberately not deployed: it is the pre-canonical implementation.
foreach ($name in @('Run-Scheduled.ps1', 'Run-WeeklyPipeline.ps1', 'Test-Reconcile.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root (Join-Path 'scripts' $name)) -Destination (Join-Path $VaultRoot 'scripts') -Force
}

# The canonical PowerShell implementation was proven on the Oracle VM.  Its
# logic is platform-neutral; only its old filenames were Linux-specific.
$canonicalScripts = @{
    'weekly_update_channel_wiki_v8_linux.ps1'    = 'weekly_update_channel_wiki_v8.ps1'
    'qa_reconcile_sources_v3_linux.ps1'          = 'qa_reconcile_sources_v3.ps1'
    'post_synthesis_completion_v1_linux.ps1'     = 'post_synthesis_completion_v1.ps1'
    'run_weekly_agentic_pipeline_v2_linux.ps1'   = 'run_weekly_agentic_pipeline_v2.ps1'
}
foreach ($entry in $canonicalScripts.GetEnumerator()) {
    Copy-Item -LiteralPath (Join-Path $root (Join-Path 'linux/scripts' $entry.Key)) -Destination (Join-Path $VaultRoot (Join-Path 'scripts' $entry.Value)) -Force
}

Write-Host "Vault initialised: $VaultRoot" -ForegroundColor Green
Write-Host "Next: copy config/vault.example.json to config/vault.json, edit it, then run scripts/run_weekly_agentic_pipeline_v2.ps1."
