<#
.SYNOPSIS
  No-op stand-in for weekly_update_channel_wiki_v8.ps1, used only by
  tests/Test-PromptFreshnessMatching.ps1 to isolate run_weekly_agentic_pipeline_v2's own
  pending-row / prompt-matching logic ("Finding E") from real network, yt-dlp, and ingest
  concerns.

.DESCRIPTION
  The test driver pre-seeds data/manifest.csv, prompts/*.md, and
  reports/latest_weekly_update.md directly before invoking the orchestrator with
  -UpdaterScriptName pointing at this file. This script intentionally does nothing else
  and always exits 0, so the orchestrator's own required-file check
  (Test-Path $latestWeeklyPath) passes against the driver's pre-seeded report.
#>

[CmdletBinding()]
param(
    [string]$VaultRoot = (Get-Location).Path,
    [switch]$Apply
)

exit 0
