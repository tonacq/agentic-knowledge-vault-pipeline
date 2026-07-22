<#
.SYNOPSIS
  Verifies and finalises the latest completed synthesis batch.

.DESCRIPTION
  Version: 1
  Status: Development candidate

  This script checks the latest synthesis batch in data/manifest.csv, confirms
  that every row is marked included and has synthesis evidence, runs the source
  reconciliation QA, optionally applies deterministic fixes, reruns QA, and
  writes a clear BATCH COMPLETE or ACTION REQUIRED report.

  It does not perform synthesis and does not change synthesis fields in the
  manifest. Claude Code remains responsible for marking synthesis completion.

.EXAMPLES
  Safe verification only:
    powershell -ExecutionPolicy Bypass -File ".\scripts\post_synthesis_completion_v1.ps1" -ReportOnly

  Finalise latest batch and apply deterministic QA fixes:
    powershell -ExecutionPolicy Bypass -File ".\scripts\post_synthesis_completion_v1.ps1" -Apply

  Verify a named batch:
    powershell -ExecutionPolicy Bypass -File ".\scripts\post_synthesis_completion_v1.ps1" -ReportOnly -Batch "Batch 29"
#>

param(
    [string]$VaultRoot = (Get-Location).Path,
    [string]$Batch = "",
    [string]$QaScriptName = "qa_reconcile_sources_v3.ps1",
    [switch]$ReportOnly,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

if ($Apply -and $ReportOnly) {
    throw "Use either -Apply or -ReportOnly, not both."
}
if (-not $Apply -and -not $ReportOnly) {
    $ReportOnly = $true
}

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

function Get-Field($Row, [string]$Name) {
    if ($Row.PSObject.Properties.Name -contains $Name) {
        return [string]$Row.$Name
    }
    return ""
}

function Get-BatchNumber([string]$Value) {
    if ($Value -match '(\d+)') { return [int]$Matches[1] }
    return -1
}

function Parse-DateValue([string]$Value) {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return [datetime]::MinValue
}

function Get-QaMetric([string[]]$Lines, [string]$Label) {
    foreach ($line in $Lines) {
        if ($line -match ('^' + [regex]::Escape($Label) + ':\s*(\d+)')) {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Invoke-Qa([string]$ScriptPath, [bool]$UseApply) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    )
    if ($UseApply) { $arguments += '-Apply' }

    $output = @(& pwsh @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) { Write-Host $line }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
        MissingSourcePages = Get-QaMetric -Lines $output -Label 'Missing source pages'
        MissingCleanTranscripts = Get-QaMetric -Lines $output -Label 'Missing clean transcripts'
        TemplateArtefacts = Get-QaMetric -Lines $output -Label 'Rows with template artefacts'
        StalePendingText = Get-QaMetric -Lines $output -Label 'Rows with stale pending synthesis text'
        MissingEvidencePaths = Get-QaMetric -Lines $output -Label 'Rows with missing synthesis evidence paths'
        SourcePagesChanged = Get-QaMetric -Lines $output -Label 'Source pages that would change / changed'
        ManifestPathsChanged = Get-QaMetric -Lines $output -Label 'Manifest path rows that would update / updated'
    }
}

function Test-QaClean($QaResult) {
    if ($QaResult.ExitCode -ne 0) { return $false }

    $metrics = @(
        $QaResult.MissingSourcePages,
        $QaResult.MissingCleanTranscripts,
        $QaResult.TemplateArtefacts,
        $QaResult.StalePendingText,
        $QaResult.MissingEvidencePaths,
        $QaResult.SourcePagesChanged,
        $QaResult.ManifestPathsChanged
    )

    foreach ($metric in $metrics) {
        if ($null -eq $metric -or $metric -ne 0) { return $false }
    }
    return $true
}

function Write-CompletionReport(
    [string]$Path,
    [string]$LatestPath,
    [string]$Status,
    [string]$Mode,
    [string]$SelectedBatch,
    [object[]]$BatchRows,
    [object[]]$IncompleteRows,
    [object[]]$MissingEvidenceRows,
    $InitialQa,
    $FinalQa,
    [string]$StartedAt,
    [string]$FinishedAt,
    [string]$Notes
) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('---')
    $lines.Add('type: report')
    $lines.Add('report_type: post_synthesis_completion')
    $lines.Add(('created: {0}' -f (Get-Date -Format 'yyyy-MM-dd')))
    $lines.Add(('mode: {0}' -f $Mode))
    $lines.Add('---')
    $lines.Add('')
    $lines.Add('# Post-Synthesis Completion Check')
    $lines.Add('')
    $lines.Add(('## **{0}**' -f $Status))
    $lines.Add('')
    $lines.Add(('- Batch: **{0}**' -f $SelectedBatch))
    $lines.Add(('- Rows checked: {0}' -f $BatchRows.Count))
    $lines.Add(('- Rows not marked included: {0}' -f $IncompleteRows.Count))
    $lines.Add(('- Rows missing synthesis evidence: {0}' -f $MissingEvidenceRows.Count))
    $lines.Add(('- Mode: {0}' -f $Mode))
    $lines.Add(('- Started: {0}' -f $StartedAt))
    $lines.Add(('- Finished: {0}' -f $FinishedAt))
    $lines.Add('')
    $lines.Add('## Final QA')
    $lines.Add('')
    $lines.Add(('- Missing source pages: {0}' -f $FinalQa.MissingSourcePages))
    $lines.Add(('- Missing clean transcripts: {0}' -f $FinalQa.MissingCleanTranscripts))
    $lines.Add(('- Template artefacts: {0}' -f $FinalQa.TemplateArtefacts))
    $lines.Add(('- Stale pending synthesis text: {0}' -f $FinalQa.StalePendingText))
    $lines.Add(('- Missing synthesis evidence paths: {0}' -f $FinalQa.MissingEvidencePaths))
    $lines.Add(('- Source pages requiring changes: {0}' -f $FinalQa.SourcePagesChanged))
    $lines.Add(('- Manifest path rows requiring changes: {0}' -f $FinalQa.ManifestPathsChanged))

    if ($Apply) {
        $lines.Add('')
        $lines.Add('## QA application')
        $lines.Add('')
        $lines.Add(('- Initial source pages requiring changes: {0}' -f $InitialQa.SourcePagesChanged))
        $lines.Add('- Deterministic QA fixes were applied before the final verification run.')
    }

    if ($IncompleteRows.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Rows not marked included')
        $lines.Add('')
        foreach ($row in $IncompleteRows) {
            $lines.Add(('- {0} - {1} - status: {2}' -f (Get-Field $row 'video_id'), (Get-Field $row 'title'), (Get-Field $row 'synthesis_status')))
        }
    }

    if ($MissingEvidenceRows.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Rows missing synthesis evidence')
        $lines.Add('')
        foreach ($row in $MissingEvidenceRows) {
            $lines.Add(('- {0} - {1}' -f (Get-Field $row 'video_id'), (Get-Field $row 'title')))
        }
    }

    $lines.Add('')
    $lines.Add('## Notes')
    $lines.Add('')
    $lines.Add($Notes)

    $tempPath = "$Path.tmp"
    Set-Content -LiteralPath $tempPath -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force

    Copy-Item -LiteralPath $Path -Destination $LatestPath -Force
}

$startedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$mode = if ($Apply) { 'APPLY' } else { 'REPORT ONLY' }

$VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
$manifestPath = Join-Path $VaultRoot (Join-Path 'data' 'manifest.csv')
$qaScriptPath = Join-Path $VaultRoot (Join-Path 'scripts' $QaScriptName)
$reportsDir = Join-Path $VaultRoot 'reports'
$reportPath = Join-Path $reportsDir "post_synthesis_completion_$stamp.md"
$latestReportPath = Join-Path $reportsDir 'latest_post_synthesis_completion.md'

if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }
if (-not (Test-Path -LiteralPath $qaScriptPath)) { throw "QA script not found: $qaScriptPath" }
if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null }

Write-Info 'Post-synthesis completion check'
Write-Host "Vault: $VaultRoot"
Write-Host "Mode:  $mode"

$rows = @(Import-Csv -LiteralPath $manifestPath)
if ($rows.Count -eq 0) { throw 'Manifest contains no data rows.' }

$batchRowsWithValue = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace((Get-Field $_ 'synthesis_batch')) })
if ($batchRowsWithValue.Count -eq 0) { throw 'No synthesis_batch values were found in the manifest.' }

$selectedBatch = $Batch
if ([string]::IsNullOrWhiteSpace($selectedBatch)) {
    $batchSummary = @(
        $batchRowsWithValue |
            Group-Object { Get-Field $_ 'synthesis_batch' } |
            ForEach-Object {
                $latestDate = [datetime]::MinValue
                foreach ($row in $_.Group) {
                    $candidate = Parse-DateValue (Get-Field $row 'synthesis_last_checked')
                    if ($candidate -gt $latestDate) { $latestDate = $candidate }
                }
                [pscustomobject]@{
                    Batch = $_.Name
                    BatchNumber = Get-BatchNumber $_.Name
                    LatestDate = $latestDate
                }
            } |
            Sort-Object @{Expression='LatestDate';Descending=$true}, @{Expression='BatchNumber';Descending=$true}
    )
    $selectedBatch = $batchSummary[0].Batch
}

$batchRows = @($rows | Where-Object { (Get-Field $_ 'synthesis_batch') -eq $selectedBatch })
if ($batchRows.Count -eq 0) { throw "No manifest rows found for synthesis batch: $selectedBatch" }

Write-Host "Batch: $selectedBatch"
Write-Host "Rows:  $($batchRows.Count)"

$incompleteRows = @($batchRows | Where-Object { (Get-Field $_ 'synthesis_status').Trim().ToLowerInvariant() -ne 'included' })
$missingEvidenceRows = @($batchRows | Where-Object { [string]::IsNullOrWhiteSpace((Get-Field $_ 'synthesis_evidence')) })

if ($incompleteRows.Count -gt 0) {
    Write-Warn "$($incompleteRows.Count) row(s) are not marked included."
}
if ($missingEvidenceRows.Count -gt 0) {
    Write-Warn "$($missingEvidenceRows.Count) row(s) have no synthesis evidence."
}

Write-Info 'Running initial source QA...'
$initialQa = Invoke-Qa -ScriptPath $qaScriptPath -UseApply:$false
$finalQa = $initialQa

$manifestReady = ($incompleteRows.Count -eq 0 -and $missingEvidenceRows.Count -eq 0)

if ($Apply -and $manifestReady) {
    Write-Info 'Applying deterministic QA fixes...'
    $applyQa = Invoke-Qa -ScriptPath $qaScriptPath -UseApply:$true
    if ($applyQa.ExitCode -ne 0) {
        throw "QA apply run failed with exit code $($applyQa.ExitCode)."
    }

    Write-Info 'Running final source QA...'
    $finalQa = Invoke-Qa -ScriptPath $qaScriptPath -UseApply:$false
} elseif ($Apply -and -not $manifestReady) {
    Write-Warn 'QA fixes were not applied because the batch manifest state is incomplete.'
}

$qaClean = Test-QaClean $finalQa
$status = 'ACTION REQUIRED'
$notes = 'Review the incomplete manifest rows or QA exceptions listed above, then rerun this script.'
$exitCode = 2

if ($manifestReady -and $qaClean) {
    $status = 'BATCH COMPLETE'
    $notes = 'All rows in the selected synthesis batch are included, synthesis evidence is present, and final source QA is clean.'
    $exitCode = 0
}

$finishedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-CompletionReport `
    -Path $reportPath `
    -LatestPath $latestReportPath `
    -Status $status `
    -Mode $mode `
    -SelectedBatch $selectedBatch `
    -BatchRows $batchRows `
    -IncompleteRows $incompleteRows `
    -MissingEvidenceRows $missingEvidenceRows `
    -InitialQa $initialQa `
    -FinalQa $finalQa `
    -StartedAt $startedAt `
    -FinishedAt $finishedAt `
    -Notes $notes

Write-Host ''
if ($status -eq 'BATCH COMPLETE') {
    Write-Ok $status
} else {
    Write-Warn $status
}
Write-Host "Report:        $reportPath"
Write-Host "Latest report: $latestReportPath"

exit $exitCode
