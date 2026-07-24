<#
.SYNOPSIS
  Deterministic stand-in for qa_reconcile_sources_v3.ps1, used only by
  tests/Test-PostSynthesisGate.ps1 to exercise post_synthesis_completion_v1_linux.ps1's
  BATCH COMPLETE / ACTION REQUIRED gate without needing a real vault, real transcripts,
  or Claude.

.DESCRIPTION
  Reads data/manifest.csv from -VaultRoot and, for each row, checks real file existence
  of source_file and clean_transcript_file (exactly like the aggregate counts the real QA
  script produces), then writes a per-row CSV with video_id / synthesis_status /
  source_exists / clean_exists columns -- matching the shape post_synthesis_completion_v1's
  Get-UnexpectedMissingRows expects. Test scenarios control outcomes purely by whether they
  create the referenced files and how they populate the manifest, not via environment
  variables, so this fixture stays a faithful (if simplified) stand-in for the real script.

  Does not call Claude. Does not modify raw/ or data/clean_transcripts/.
#>

[CmdletBinding()]
param(
    [string]$VaultRoot = (Get-Location).Path,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Get-Field($Row, [string]$Name) {
    if ($Row.PSObject.Properties.Name -contains $Name) { return [string]$Row.$Name }
    return ""
}

$mode = if ($Apply) { 'APPLY' } else { 'REPORT ONLY' }
$VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
$manifestPath = Join-Path $VaultRoot (Join-Path 'data' 'manifest.csv')
$reportsDir = Join-Path $VaultRoot 'reports'
if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null }

$rows = @(Import-Csv -LiteralPath $manifestPath)
$results = New-Object System.Collections.Generic.List[object]
$sourceMissing = 0
$cleanMissing = 0

foreach ($row in $rows) {
    $videoId = Get-Field $row 'video_id'
    $synthStatus = Get-Field $row 'synthesis_status'
    $sourceRel = Get-Field $row 'source_file'
    $cleanRel = Get-Field $row 'clean_transcript_file'

    $sourceExists = (-not [string]::IsNullOrWhiteSpace($sourceRel)) -and (Test-Path -LiteralPath (Join-Path $VaultRoot $sourceRel))
    $cleanExists = (-not [string]::IsNullOrWhiteSpace($cleanRel)) -and (Test-Path -LiteralPath (Join-Path $VaultRoot $cleanRel))

    if (-not $sourceExists) { $sourceMissing++ }
    if (-not $cleanExists) { $cleanMissing++ }

    $results.Add([pscustomobject]@{
        video_id = $videoId
        synthesis_status = $synthStatus
        source_exists = $sourceExists
        clean_exists = $cleanExists
    }) | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fffffff'
$csvPath = Join-Path $reportsDir "fake_qa_reconciliation_$stamp.csv"
$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

Write-Host 'QA reconciliation complete'
Write-Host "Mode: $mode"
Write-Host "Rows checked: $($rows.Count)"
Write-Host "Missing source pages: $sourceMissing"
Write-Host "Missing clean transcripts: $cleanMissing"
Write-Host 'Rows with template artefacts: 0'
Write-Host 'Rows with stale pending synthesis text: 0'
Write-Host 'Rows with missing synthesis evidence paths: 0'
Write-Host 'Source pages that would change / changed: 0'
Write-Host 'Source pages found by fallback: 0'
Write-Host 'Clean transcripts found by fallback: 0'
Write-Host 'Manifest path rows that would update / updated: 0'
Write-Host "CSV:    $csvPath"

exit 0
