[CmdletBinding()]
param([Parameter(Mandatory)][string]$VaultRoot)
$ErrorActionPreference = 'Stop'
$dirs = 'raw','data/clean_transcripts','wiki/sources','prompts','reports'
foreach ($dir in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $VaultRoot $dir) | Out-Null }
$manifest = Join-Path $VaultRoot 'data/manifest.csv'
if (-not (Test-Path $manifest)) {
  'video_id,title,url,upload_date,transcript_file,transcript_status,source_file,source_status,synthesis_status,synthesis_evidence,last_checked' | Set-Content -Encoding utf8 $manifest
}
Write-Host "Initialised vault: $([IO.Path]::GetFullPath($VaultRoot))" -ForegroundColor Green
