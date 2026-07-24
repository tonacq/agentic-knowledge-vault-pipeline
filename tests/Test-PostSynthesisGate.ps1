<#
.SYNOPSIS
  Regression test for the post_synthesis_completion_v1_linux.ps1 completion gate
  (the "Bug C" fix: legitimately blocked_missing_transcript rows must not permanently
  block BATCH COMPLETE, while genuine defects must still be caught).

.DESCRIPTION
  Builds three throwaway, isolated fake vaults and runs the real
  linux/scripts/post_synthesis_completion_v1_linux.ps1 against each one, using
  tests/fake-qa-reconcile.ps1 in place of the real QA script (via -QaScriptName) so this
  test needs no real transcripts, no real yt-dlp, and never calls Claude.

  Scenario 1: a completed batch with two unrelated blocked_missing_transcript rows
              (correctly missing both a source page and a clean transcript, as the
              real ingest pipeline leaves them) -> expected exit 0 (BATCH COMPLETE).
  Scenario 2: a batch row not marked 'included' (genuinely incomplete manifest state,
              unrelated to this fix) -> expected non-zero exit. Confirms the existing
              manifestReady check is untouched by this fix.
  Scenario 3: a completed batch where an *included* row's source page is unexpectedly
              missing from disk (a genuine defect, not a known-blocked row) -> expected
              non-zero exit. Confirms the fix does not mask real problems.

  This test must be run against a version of post_synthesis_completion_v1_linux.ps1 that
  includes the Bug C patch (Get-UnexpectedMissingRows / per-row CSV cross-check). Run
  against the unpatched script, scenarios 1 and 3 are expected to fail, since the
  unpatched gate hard-fails on any nonzero Missing source pages / Missing clean
  transcripts count regardless of cause.
#>

[CmdletBinding()]
param([string]$Workspace = (Join-Path ([IO.Path]::GetTempPath()) 'wiki-agent-post-synthesis-gate-test'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$targetScript = Join-Path $root 'linux\scripts\post_synthesis_completion_v1_linux.ps1'
$fixtureQa = Join-Path $root 'tests\fake-qa-reconcile.ps1'

if (-not (Test-Path -LiteralPath $targetScript)) { throw "Target script not found: $targetScript" }
if (-not (Test-Path -LiteralPath $fixtureQa)) { throw "Fixture QA script not found: $fixtureQa" }

function New-TestVault([string]$Path, [string[]]$ManifestRows) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -Recurse -Force -LiteralPath $Path }
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'data') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'reports') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'wiki\sources') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'data\clean_transcripts') | Out-Null
    Copy-Item -LiteralPath $fixtureQa -Destination (Join-Path $Path 'scripts\fake-qa-reconcile.ps1') -Force

    $header = 'video_id,title,synthesis_batch,synthesis_status,synthesis_evidence,source_file,clean_transcript_file'
    $csv = @($header) + $ManifestRows
    Set-Content -LiteralPath (Join-Path $Path 'data\manifest.csv') -Value $csv -Encoding utf8
}

function New-DummyFile([string]$VaultPath, [string]$RelativePath) {
    $full = Join-Path $VaultPath $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
    Set-Content -LiteralPath $full -Value 'placeholder' -Encoding utf8
}

function Invoke-Gate([string]$Path) {
    # Capture child stdout into a variable (not the function's own output stream) so the
    # function's return value is the exit code alone, not [captured lines..., exit code].
    # $LASTEXITCODE is read immediately after the native pwsh call, before anything else
    # can overwrite it.
    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $targetScript -VaultRoot $Path -QaScriptName 'fake-qa-reconcile.ps1' -Apply
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host $line }
    return [int]$code
}

$failures = New-Object System.Collections.Generic.List[string]

# --- Scenario 1: completed batch, two unrelated blocked_missing_transcript rows -> exit 0 ---
$v1 = Join-Path $Workspace 'scenario1'
New-TestVault -Path $v1 -ManifestRows @(
    'vidBlockedA,Blocked A,,blocked_missing_transcript,,,',
    'vidBlockedB,Blocked B,,blocked_missing_transcript,,,',
    'vidGood,Good Video,TESTBATCH,included,wiki\synthesis\synthesis_register.md,wiki\sources\vidGood.md,data\clean_transcripts\vidGood.md'
)
New-DummyFile -VaultPath $v1 -RelativePath 'wiki\sources\vidGood.md'
New-DummyFile -VaultPath $v1 -RelativePath 'data\clean_transcripts\vidGood.md'
New-DummyFile -VaultPath $v1 -RelativePath 'wiki\synthesis\synthesis_register.md'
$code1 = Invoke-Gate -Path $v1
if ($code1 -ne 0) { $failures.Add("Scenario 1 (completed batch, unrelated blocked rows): expected exit 0, got $code1") }
else { Write-Host 'Scenario 1 PASSED (exit 0)' -ForegroundColor Green }

# --- Scenario 2: genuinely incomplete batch (row not marked included) -> non-zero exit ---
$v2 = Join-Path $Workspace 'scenario2'
New-TestVault -Path $v2 -ManifestRows @(
    'vidBlockedA,Blocked A,,blocked_missing_transcript,,,',
    'vidBlockedB,Blocked B,,blocked_missing_transcript,,,',
    'vidPending,Pending Video,TESTBATCH,pending,,,'
)
$code2 = Invoke-Gate -Path $v2
if ($code2 -eq 0) { $failures.Add('Scenario 2 (genuinely incomplete batch): expected non-zero exit, got 0') }
else { Write-Host "Scenario 2 PASSED (exit $code2)" -ForegroundColor Green }

# --- Scenario 3: completed batch, but an included row's source page is unexpectedly missing -> non-zero exit ---
$v3 = Join-Path $Workspace 'scenario3'
New-TestVault -Path $v3 -ManifestRows @(
    'vidBlockedA,Blocked A,,blocked_missing_transcript,,,',
    'vidBlockedB,Blocked B,,blocked_missing_transcript,,,',
    'vidGood,Good Video,TESTBATCH,included,wiki\synthesis\synthesis_register.md,wiki\sources\vidGood_MISSING.md,data\clean_transcripts\vidGood.md'
)
# Deliberately do NOT create wiki\sources\vidGood_MISSING.md -- simulates an unexplained
# missing source page on an otherwise-included, non-blocked row.
New-DummyFile -VaultPath $v3 -RelativePath 'data\clean_transcripts\vidGood.md'
New-DummyFile -VaultPath $v3 -RelativePath 'wiki\synthesis\synthesis_register.md'
$code3 = Invoke-Gate -Path $v3
if ($code3 -eq 0) { $failures.Add('Scenario 3 (unexplained missing source page on a non-blocked row): expected non-zero exit, got 0') }
else { Write-Host "Scenario 3 PASSED (exit $code3)" -ForegroundColor Green }

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host "FAILED: $f" -ForegroundColor Red }
    throw "$($failures.Count) of 3 regression scenario(s) failed."
}

Write-Host ''
Write-Host 'All post-synthesis completion gate regression scenarios passed.' -ForegroundColor Green
