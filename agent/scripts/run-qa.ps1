<#
.SYNOPSIS
The single authoritative, idempotent reconciliation pass. Reads
working/temp/synthesis-result.json (if present from this run) plus the current state of
wiki/sources/*.md, and updates working/manifest.csv accordingly.

.DESCRIPTION
Carries forward two specific fixes from the validated production history:

  Finding D fix: never downgrade a row already marked synthesis_status = included back
  to pending. An interrupted run must never destroy evidence that synthesis already
  completed for that row.

  Idempotency requirement: running this twice in a row with no new work must produce
  zero manifest changes (verified separately by agent/tests).

Also checks for template artefacts left behind in source/synthesis pages (unresolved
"REPLACE_ME" or leftover mechanical-template markers) and reports them without
"fixing" them silently — a human or Claude should resolve real content gaps.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$resultFile   = Join-Path $VaultRoot 'working/temp/synthesis-result.json'
$manifest = @(Import-Csv -LiteralPath $manifestPath)
$changed = 0
$templateArtefacts = 0

if (Test-Path -LiteralPath $resultFile) {
    $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    $processedIds = @($result.processed)

    foreach ($row in $manifest) {
        if ($processedIds -notcontains $row.video_id) { continue }
        if ($row.synthesis_status -eq 'included') { continue }  # Finding D: never downgrade

        $row.synthesis_status       = 'included'
        $row.synthesis_last_checked = (Get-Date).ToString('yyyy-MM-dd')
        $row.synthesis_evidence     = ($result.pages_created + $result.pages_updated) -join '; '
        $row.synthesis_batch        = $result.batch
        $row.last_updated           = (Get-Date).ToString('o')
        $changed++
    }

    Move-Item -LiteralPath $resultFile -Destination "$resultFile.$($result.batch).processed" -Force
}

# Report-only template-artefact scan (does not modify anything)
Get-ChildItem -LiteralPath (Join-Path $VaultRoot 'wiki') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw
        if ($text -match 'REPLACE_ME|EXTRACTION PENDING|TODO_TEMPLATE') { $templateArtefacts++ }
    }

if ($changed -gt 0) {
    $tmp = "$manifestPath.tmp"
    $manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

$missingSourcePages = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and -not (Test-Path -LiteralPath $_.source_file) }).Count

Write-Host "QA reconciliation complete."
Write-Host "  Rows updated to included: $changed"
Write-Host "  Rows with missing source pages: $missingSourcePages"
Write-Host "  Pages with template artefacts remaining: $templateArtefacts"

if ($missingSourcePages -gt 0) {
    Write-Warning "$missingSourcePages row(s) reference a source_file that does not exist on disk."
}
