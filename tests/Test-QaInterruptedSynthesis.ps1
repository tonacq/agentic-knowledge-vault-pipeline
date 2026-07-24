<#
.SYNOPSIS
  Regression test for the qa_reconcile_sources_v3_linux.ps1 "Finding D" fix: a source
  page whose text already claims synthesis is included must not be silently downgraded
  by QA just because the manifest hasn't (yet) caught up -- the signature of an
  interrupted synthesis run.

.DESCRIPTION
  Builds one disposable fake vault with three manifest rows / source pages covering:

  Scenario 1: manifest=pending, page text=included (the interruption case) ->
              -Apply must leave the page's synthesis_status untouched and report it
              via the new "possible interrupted synthesis" metric, not silently fix it.
  Scenario 2: manifest=included, page text=pending (the pre-existing stale_pending_text
              case) -> -Apply must still correct it exactly as before this patch.
  Scenario 3: manifest and page already agree (both included) -> no change either way.

  Runs the real (patched) qa_reconcile_sources_v3_linux.ps1 -Apply. No network, no
  Claude, no dependency on any other vault.
#>

[CmdletBinding()]
param([string]$Workspace = (Join-Path ([IO.Path]::GetTempPath()) 'wiki-agent-qa-interrupted-synthesis-test'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$targetScript = Join-Path $root 'linux\scripts\qa_reconcile_sources_v3_linux.ps1'
if (-not (Test-Path -LiteralPath $targetScript)) { throw "Target script not found: $targetScript" }

if (Test-Path -LiteralPath $Workspace) { Remove-Item -Recurse -Force -LiteralPath $Workspace }
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace 'data') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace 'wiki\sources') | Out-Null

function New-SourcePage([string]$Path, [string]$Status) {
    $lines = @(
        '---',
        'video_id: "x"',
        "synthesis_status: `"$Status`"",
        '---',
        '',
        '# Test Source Page'
    )
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

New-SourcePage -Path (Join-Path $Workspace 'wiki\sources\scenario1_interrupted.md') -Status 'included'
New-SourcePage -Path (Join-Path $Workspace 'wiki\sources\scenario2_stale_pending.md') -Status 'pending'
New-SourcePage -Path (Join-Path $Workspace 'wiki\sources\scenario3_agree.md') -Status 'included'

$header = 'video_id,title,synthesis_status,source_status,source_file,clean_transcript_file,synthesis_evidence'
$rows = @(
    $header,
    'scenario1,Scenario 1 - interrupted,pending,source_exists,wiki\sources\scenario1_interrupted.md,,',
    'scenario2,Scenario 2 - stale pending,included,source_exists,wiki\sources\scenario2_stale_pending.md,,',
    'scenario3,Scenario 3 - agree,included,source_exists,wiki\sources\scenario3_agree.md,,'
)
Set-Content -LiteralPath (Join-Path $Workspace 'data\manifest.csv') -Value $rows -Encoding utf8

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $targetScript -VaultRoot $Workspace -Apply
$code = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }

$failures = New-Object System.Collections.Generic.List[string]

if ($code -ne 0) { $failures.Add("QA script exited $code, expected 0") }

$interruptedLine = $output | Where-Object { $_ -match '^Rows with possible interrupted synthesis:\s*(\d+)' }
$interruptedCount = if ($interruptedLine -and ($interruptedLine -match '(\d+)')) { [int]$Matches[1] } else { -1 }
if ($interruptedCount -ne 1) { $failures.Add("Expected exactly 1 row flagged as possible interrupted synthesis, got $interruptedCount") }

$staleLine = $output | Where-Object { $_ -match '^Rows with stale pending synthesis text:\s*(\d+)' }
$staleCount = if ($staleLine -and ($staleLine -match '(\d+)')) { [int]$Matches[1] } else { -1 }
if ($staleCount -ne 1) { $failures.Add("Expected exactly 1 row flagged as stale pending synthesis text (pre-existing check, must be unaffected), got $staleCount") }

$s1 = Get-Content -Raw (Join-Path $Workspace 'wiki\sources\scenario1_interrupted.md')
if ($s1 -notmatch '(?im)^synthesis_status:\s*"included"\s*$') {
    $failures.Add('Scenario 1: source page synthesis_status was changed from "included" -- the interruption signal was erased, fix did not take effect')
} else {
    Write-Host 'Scenario 1 PASSED (page text preserved as "included", flagged not silently fixed)' -ForegroundColor Green
}

$s2 = Get-Content -Raw (Join-Path $Workspace 'wiki\sources\scenario2_stale_pending.md')
if ($s2 -notmatch '(?im)^synthesis_status:\s*"included"\s*$') {
    $failures.Add('Scenario 2: source page synthesis_status was NOT corrected to "included" -- pre-existing stale_pending_text fix regressed')
} else {
    Write-Host 'Scenario 2 PASSED (pre-existing stale-pending fix still applies)' -ForegroundColor Green
}

$s3 = Get-Content -Raw (Join-Path $Workspace 'wiki\sources\scenario3_agree.md')
if ($s3 -notmatch '(?im)^synthesis_status:\s*"included"\s*$') {
    $failures.Add('Scenario 3: source page synthesis_status changed unexpectedly when manifest and page already agreed')
} else {
    Write-Host 'Scenario 3 PASSED (no spurious change when already consistent)' -ForegroundColor Green
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host "FAILED: $f" -ForegroundColor Red }
    throw "$($failures.Count) of 3 regression scenario(s) failed."
}

Write-Host ''
Write-Host 'All Finding D regression scenarios passed.' -ForegroundColor Green
