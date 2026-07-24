<#
.SYNOPSIS
  Regression test for the run_weekly_agentic_pipeline_v2_linux.ps1 "Finding E" fix:
  pending rows must be matched to the correct, current prompt rather than an arbitrary
  stale historical one.

.DESCRIPTION
  Uses tests/fake-weekly-updater.ps1 (via -UpdaterScriptName) to isolate the
  orchestrator's own pending-row / prompt-matching logic from real network/yt-dlp/ingest
  concerns and from Claude (-SkipClaude is also used). Each scenario pre-seeds
  data/manifest.csv, prompts/*.md (with controlled LastWriteTime), and
  reports/latest_weekly_update.md directly, then runs the real (patched)
  run_weekly_agentic_pipeline_v2_linux.ps1 and inspects its own final report.

  Scenario 1: a pending row is covered by the just-reported "fresh" prompt, and an
              older decoy prompt also happens to mention the same video ID -> the fresh
              prompt must be selected, not the decoy.
  Scenario 2: a pending row is NOT covered by the fresh prompt (simulates a row pending
              from before this run, e.g. an interrupted prior run), with two historical
              candidate prompts of different ages both mentioning the video ID -> the
              newer one must be selected, not the older one.
  Scenario 3: a pending row has no matching prompt anywhere -> the existing
              "no matching prompt" failure must still fire (non-zero exit), unchanged.
#>

[CmdletBinding()]
param([string]$Workspace = (Join-Path ([IO.Path]::GetTempPath()) 'wiki-agent-prompt-freshness-test'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$targetScript = Join-Path $root 'linux\scripts\run_weekly_agentic_pipeline_v2_linux.ps1'
$fakeUpdater = Join-Path $root 'tests\fake-weekly-updater.ps1'
$realPostScript = Join-Path $root 'linux\scripts\post_synthesis_completion_v1_linux.ps1'
if (-not (Test-Path -LiteralPath $targetScript)) { throw "Target script not found: $targetScript" }
if (-not (Test-Path -LiteralPath $fakeUpdater)) { throw "Fake updater not found: $fakeUpdater" }

function New-TestVault([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -Recurse -Force -LiteralPath $Path }
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'data') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'reports') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'prompts') | Out-Null
    Copy-Item -LiteralPath $fakeUpdater -Destination (Join-Path $Path 'scripts\fake-weekly-updater.ps1') -Force
    # Never actually invoked under -SkipClaude, but the orchestrator checks it exists.
    Copy-Item -LiteralPath $realPostScript -Destination (Join-Path $Path 'scripts\post_synthesis_completion_v1.ps1') -Force
}

function New-Prompt([string]$VaultPath, [string]$Name, [string]$VideoId, [datetime]$WriteTime) {
    $path = Join-Path $VaultPath "prompts\$Name"
    Set-Content -LiteralPath $path -Value @(
        "# Weekly Synthesis Prompt",
        "## New source pages",
        "- wiki\sources\dummy_${VideoId}.md - Dummy title for $VideoId"
    ) -Encoding utf8
    (Get-Item -LiteralPath $path).LastWriteTime = $WriteTime
    return $path
}

function New-Manifest([string]$VaultPath, [string]$VideoId) {
    $rows = @(
        'video_id,title,synthesis_status',
        "$VideoId,Test Video,pending"
    )
    Set-Content -LiteralPath (Join-Path $VaultPath 'data\manifest.csv') -Value $rows -Encoding utf8
}

function New-LatestWeeklyUpdate([string]$VaultPath, [string]$PromptRelative) {
    $lines = @(
        '# Latest Weekly Wiki Update',
        '- Run status: **PARTIAL**',
        '- Mode: APPLY',
        '- New videos found: 0',
        '- Synthesis required: **YES**',
        "- Prompt generated: $PromptRelative"
    )
    Set-Content -LiteralPath (Join-Path $VaultPath 'reports\latest_weekly_update.md') -Value $lines -Encoding utf8
}

function Invoke-Orchestrator([string]$VaultPath) {
    $script:lastOrchestratorOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $targetScript -VaultRoot $VaultPath -UpdaterScriptName 'fake-weekly-updater.ps1' -SkipClaude 2>&1 |
        ForEach-Object { [string]$_ }
    return [int]$LASTEXITCODE
}

$failures = New-Object System.Collections.Generic.List[string]
$now = Get-Date

# --- Scenario 1: fresh prompt covers the row; older decoy also matches -> fresh wins ---
$v1 = Join-Path $Workspace 'scenario1'
New-TestVault -Path $v1
New-Prompt -VaultPath $v1 -Name 'weekly_synthesis_decoy_old.md' -VideoId 'vidFresh' -WriteTime $now.AddHours(-5) | Out-Null
$freshPath = New-Prompt -VaultPath $v1 -Name 'weekly_synthesis_fresh.md' -VideoId 'vidFresh' -WriteTime $now
New-Manifest -VaultPath $v1 -VideoId 'vidFresh'
New-LatestWeeklyUpdate -VaultPath $v1 -PromptRelative 'prompts/weekly_synthesis_fresh.md'
$code1 = Invoke-Orchestrator -VaultPath $v1
$report1 = Get-Content -Raw (Join-Path $v1 'reports\latest_weekly_agentic_pipeline.md') -ErrorAction SilentlyContinue
if ($code1 -ne 2) { $failures.Add("Scenario 1: expected exit 2 (ACTION REQUIRED - SYNTHESIS SKIPPED), got $code1") }
elseif ($report1 -notmatch [regex]::Escape('weekly_synthesis_fresh.md')) { $failures.Add("Scenario 1: final report did not cite the fresh prompt. Report:`n$report1") }
elseif ($report1 -match [regex]::Escape('weekly_synthesis_decoy_old.md')) { $failures.Add("Scenario 1: final report cited the stale decoy prompt instead of the fresh one") }
else { Write-Host 'Scenario 1 PASSED (fresh prompt selected over stale decoy)' -ForegroundColor Green }

# --- Scenario 2: row not covered by fresh prompt; two historical candidates -> newest wins ---
$v2 = Join-Path $Workspace 'scenario2'
New-TestVault -Path $v2
New-Prompt -VaultPath $v2 -Name 'weekly_synthesis_unrelated_fresh.md' -VideoId 'someOtherVideo' -WriteTime $now | Out-Null
New-Prompt -VaultPath $v2 -Name 'weekly_synthesis_hist_older.md' -VideoId 'vidOld' -WriteTime $now.AddDays(-10) | Out-Null
New-Prompt -VaultPath $v2 -Name 'weekly_synthesis_hist_newer.md' -VideoId 'vidOld' -WriteTime $now.AddDays(-1) | Out-Null
New-Manifest -VaultPath $v2 -VideoId 'vidOld'
New-LatestWeeklyUpdate -VaultPath $v2 -PromptRelative 'prompts/weekly_synthesis_unrelated_fresh.md'
$code2 = Invoke-Orchestrator -VaultPath $v2
$report2 = Get-Content -Raw (Join-Path $v2 'reports\latest_weekly_agentic_pipeline.md') -ErrorAction SilentlyContinue
if ($code2 -ne 2) { $failures.Add("Scenario 2: expected exit 2, got $code2") }
elseif ($report2 -notmatch [regex]::Escape('weekly_synthesis_hist_newer.md')) { $failures.Add("Scenario 2: final report did not cite the newer historical prompt. Report:`n$report2") }
elseif ($report2 -match [regex]::Escape('weekly_synthesis_hist_older.md')) { $failures.Add("Scenario 2: final report cited the OLDER historical prompt instead of the newer one") }
else { Write-Host 'Scenario 2 PASSED (newest historical match selected over oldest)' -ForegroundColor Green }

# --- Scenario 3: no matching prompt anywhere -> existing failure behaviour unchanged ---
$v3 = Join-Path $Workspace 'scenario3'
New-TestVault -Path $v3
New-Prompt -VaultPath $v3 -Name 'weekly_synthesis_unrelated.md' -VideoId 'someOtherVideo' -WriteTime $now | Out-Null
New-Manifest -VaultPath $v3 -VideoId 'vidMissing'
New-LatestWeeklyUpdate -VaultPath $v3 -PromptRelative 'prompts/weekly_synthesis_unrelated.md'
$code3 = Invoke-Orchestrator -VaultPath $v3
$output3 = $script:lastOrchestratorOutput -join "`n"
if ($code3 -eq 0 -or $code3 -eq 2) { $failures.Add("Scenario 3: expected a failure exit code (no matching prompt should still throw), got $code3") }
elseif ($output3 -notmatch 'no matching prompt') { $failures.Add("Scenario 3: exit code was non-zero ($code3) but not for the expected reason -- output did not mention 'no matching prompt':`n$output3") }
else { Write-Host "Scenario 3 PASSED (no-matching-prompt failure still fires, exit $code3)" -ForegroundColor Green }

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host "FAILED: $f" -ForegroundColor Red }
    throw "$($failures.Count) of 3 regression scenario(s) failed."
}

Write-Host ''
Write-Host 'All Finding E regression scenarios passed.' -ForegroundColor Green
