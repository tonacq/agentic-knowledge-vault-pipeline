<#
Script: run_weekly_agentic_pipeline_v3.ps1
Version: 3
Status: Candidate - parser fix
Purpose: Orchestrates the complete weekly YouTube knowledge-vault cycle:
         ingest -> unattended Claude synthesis -> post-synthesis QA.
Requires:
  - weekly_update_channel_wiki_v8_linux.ps1
  - post_synthesis_completion_v1_linux.ps1
  - claude CLI authenticated for the current Linux user
#>

[CmdletBinding()]
param(
    [string]$VaultRoot = (Get-Location).Path,
    [string]$UpdaterScriptName = "weekly_update_channel_wiki_v8.ps1",
    [string]$PostSynthesisScriptName = "post_synthesis_completion_v1.ps1",
    [ValidateSet("low", "medium", "high", "xhigh", "max")]
    [string]$ClaudeEffort = "high",
    [decimal]$MaxClaudeBudgetUsd = 10,
    [switch]$SkipClaude,
    [switch]$Notify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

function Get-MarkdownValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $escaped = [regex]::Escape($Label)
    $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match "^-\s*${escaped}:\s*(.*)$" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ([regex]::Match($line, "^-\s*${escaped}:\s*(.*)$")).Groups[1].Value.Trim()
}

function Convert-ToInteger {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
    $match = [regex]::Match($Value, "-?\d+")
    if (-not $match.Success) { return 0 }
    return [int]$match.Value
}

function Convert-ToVaultPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PathValue
    )

    $clean = $PathValue.Trim().Trim('`').Trim('"')
    if ([System.IO.Path]::IsPathRooted($clean)) {
        return [System.IO.Path]::GetFullPath($clean)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $clean))
}

function Write-PipelineReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LatestPath,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$StartedAt,
        [Parameter(Mandatory)][string]$FinishedAt,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][int]$NewVideos,
        [Parameter(Mandatory)][bool]$SynthesisRequired,
        [string]$PromptPath,
        [string]$ClaudeOutputPath,
        [string]$PostSynthesisReportPath,
        [string]$ErrorMessage
    )

    $lines = @(
        '---',
        'type: report',
        'report_type: weekly_agentic_pipeline',
        "created: $(Get-Date -Format 'yyyy-MM-dd')",
        "status: $Status",
        '---',
        '',
        '# Weekly Agentic Pipeline',
        '',
        "- Status: **$Status**",
        "- Started: $StartedAt",
        "- Finished: $FinishedAt",
        "- Final stage: $Stage",
        "- New videos detected: $NewVideos",
        "- Synthesis required: $(if ($SynthesisRequired) { 'YES' } else { 'NO' })",
        "- Synthesis prompt: $(if ($PromptPath) { $PromptPath } else { 'none' })",
        "- Claude output: $(if ($ClaudeOutputPath) { $ClaudeOutputPath } else { 'none' })",
        "- Post-synthesis report: $(if ($PostSynthesisReportPath) { $PostSynthesisReportPath } else { 'none' })"
    )

    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $lines += @('', '## Error', '', $ErrorMessage)
    }

    $temp = "$Path.tmp"
    Set-Content -LiteralPath $temp -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
    Copy-Item -LiteralPath $Path -Destination $LatestPath -Force
}

function Send-LocalNotification {
    param([string]$Message)
    if (-not $Notify) { return }
    try {
        & msg.exe $env:USERNAME $Message 2>$null | Out-Null
    } catch {
        Write-Warn "Notification could not be displayed: $($_.Exception.Message)"
    }
}

$startedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$status = "FAILED"
$stage = "INITIALISING"
$errorMessage = ""
$newVideos = 0
$synthesisRequired = $false
$promptPath = ""
$claudeOutputPath = ""
$postSynthesisReportPath = ""
$exitCode = 1

try {
    $VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
    $scriptsDir = Join-Path $VaultRoot "scripts"
    $reportsDir = Join-Path $VaultRoot "reports"
    $latestWeeklyPath = Join-Path $reportsDir "latest_weekly_update.md"
    $latestPostPath = Join-Path $reportsDir "latest_post_synthesis_completion.md"
    $updaterPath = Join-Path $scriptsDir $UpdaterScriptName
    $postPath = Join-Path $scriptsDir $PostSynthesisScriptName
    $reportPath = Join-Path $reportsDir "weekly_agentic_pipeline_$stamp.md"
    $latestReportPath = Join-Path $reportsDir "latest_weekly_agentic_pipeline.md"
    $claudeOutputPath = Join-Path $reportsDir "claude_weekly_synthesis_$stamp.json"

    foreach ($required in @($updaterPath, $postPath)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Required script not found: $required" }
    }
    if (-not (Test-Path -LiteralPath $reportsDir)) {
        New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    }
    if (-not $SkipClaude -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
        throw "Claude CLI was not found in PATH for the scheduled-task user."
    }

    Write-Info "Weekly agentic pipeline"
    Write-Host "Vault: $VaultRoot"

    $stage = "INGEST"
    Write-Info "Stage 1/3 - scanning and ingesting new videos..."
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $updaterPath -VaultRoot $VaultRoot -Apply
    $updaterExit = $LASTEXITCODE
    if ($updaterExit -ne 0) { throw "Updater failed with exit code $updaterExit." }
    if (-not (Test-Path -LiteralPath $latestWeeklyPath)) {
        throw "Updater completed but did not create: $latestWeeklyPath"
    }

    $newVideosValue = Get-MarkdownValue -Path $latestWeeklyPath -Label "New videos found"
    if ([string]::IsNullOrWhiteSpace($newVideosValue)) {
        $newVideosValue = Get-MarkdownValue -Path $latestWeeklyPath -Label "New videos detected"
    }
    $newVideos = Convert-ToInteger $newVideosValue

    $promptValue = Get-MarkdownValue -Path $latestWeeklyPath -Label "Prompt generated"
    if ([string]::IsNullOrWhiteSpace($promptValue)) {
        $promptValue = Get-MarkdownValue -Path $latestWeeklyPath -Label "Claude Code synthesis prompt"
    }

    $synthesisRequiredValue = Get-MarkdownValue -Path $latestWeeklyPath -Label "Synthesis required"

    # Normalise Markdown formatting and Windows-style report paths.
    if (-not [string]::IsNullOrWhiteSpace($synthesisRequiredValue)) {
        $synthesisRequiredValue = $synthesisRequiredValue.Trim().Trim("*")
    }

    if (-not [string]::IsNullOrWhiteSpace($promptValue)) {
        $promptValue = $promptValue.Trim().Trim("*").Replace("\", "/")
    }

    # This run's own freshly-reported prompt (if any) is unambiguous and cannot be
    # stale, unlike the historical prompts/ substring search used as a fallback below.
    $freshPromptPath = $null
    if (-not [string]::IsNullOrWhiteSpace($promptValue) -and $promptValue -ne "none") {
        $candidateFreshPrompt = Convert-ToVaultPath -Root $VaultRoot -PathValue $promptValue
        if (Test-Path -LiteralPath $candidateFreshPrompt) {
            $freshPromptPath = $candidateFreshPrompt
        }
    }

    $manifestPath = Join-Path $VaultRoot "data/manifest.csv"
    $promptsDir = Join-Path $VaultRoot "prompts"

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    $manifestRows = @(Import-Csv -LiteralPath $manifestPath)
    $pendingRows = @(
        $manifestRows |
            Where-Object {
                ([string]$_.synthesis_status).Trim().ToLowerInvariant() -eq "pending" -and
                ([string]$_.transcript_status).Trim().ToLowerInvariant() -eq "downloaded" -and
                ([string]$_.clean_status).Trim().ToLowerInvariant() -eq "clean_ready" -and
                ([string]$_.source_status).Trim().ToLowerInvariant() -eq "source_created"
            }
    )

    $promptPaths = [System.Collections.Generic.List[string]]::new()

    if ($pendingRows.Count -gt 0) {
        Write-Warn "Pending synthesis rows detected: $($pendingRows.Count)"

        if (-not (Test-Path -LiteralPath $promptsDir)) {
            throw "Prompts directory not found: $promptsDir"
        }

        $availablePrompts = @(
            Get-ChildItem -LiteralPath $promptsDir `
                -Filter "weekly_synthesis_*.md" `
                -File |
                Sort-Object LastWriteTime -Descending
        )

        $missingPromptVideos = [System.Collections.Generic.List[string]]::new()

        foreach ($row in $pendingRows) {
            $videoId = ([string]$row.video_id).Trim()
            if ([string]::IsNullOrWhiteSpace($videoId)) { continue }

            $matchingPrompt = $null

            # Prefer this run's own freshly-generated prompt when it covers this row --
            # avoids the historical substring search (and its inherent staleness risk)
            # entirely for the common case of a row synthesised in the same run.
            if ($freshPromptPath -and (
                Select-String -LiteralPath $freshPromptPath -SimpleMatch -Quiet -Pattern $videoId
            )) {
                $matchingPrompt = Get-Item -LiteralPath $freshPromptPath
            }

            if ($null -eq $matchingPrompt) {
                # Fallback for rows pending from before this run (e.g. an interrupted
                # prior run): search prompts/ history, newest match first, rather than
                # oldest -- minimises the chance of reusing a stale, wrongly-scoped
                # historical prompt.
                $matchingPrompt = $availablePrompts |
                    Where-Object {
                        Select-String `
                            -LiteralPath $_.FullName `
                            -SimpleMatch `
                            -Quiet `
                            -Pattern $videoId
                    } |
                    Select-Object -First 1
            }

            if ($null -eq $matchingPrompt) {
                $missingPromptVideos.Add($videoId)
                continue
            }

            if (-not $promptPaths.Contains($matchingPrompt.FullName)) {
                $promptPaths.Add($matchingPrompt.FullName)
            }
        }

        if ($missingPromptVideos.Count -gt 0) {
            throw (
                "Pending synthesis rows have no matching prompt: " +
                ($missingPromptVideos -join ", ")
            )
        }
    } elseif (
        $synthesisRequiredValue -match "^(?i:yes|true)$" -and
        -not [string]::IsNullOrWhiteSpace($promptValue) -and
        $promptValue -ne "none"
    ) {
        $reportedPromptPath = Convert-ToVaultPath `
            -Root $VaultRoot `
            -PathValue $promptValue

        if (-not (Test-Path -LiteralPath $reportedPromptPath)) {
            throw "Synthesis prompt not found: $reportedPromptPath"
        }

        $promptPaths.Add($reportedPromptPath)
    }

    $synthesisRequired = ($promptPaths.Count -gt 0)

    if (-not $synthesisRequired) {
        $status = "SUCCESS - NO SYNTHESIS REQUIRED"
        $stage = "COMPLETE"
        $exitCode = 0
        Write-Ok "No pending synthesis. Pipeline complete."
        Send-LocalNotification "YouTube knowledge vault: weekly scan complete; no synthesis required."
    } elseif ($SkipClaude) {
        $status = "ACTION REQUIRED - SYNTHESIS SKIPPED"
        $stage = "SYNTHESIS"
        $exitCode = 2
        $promptPath = $promptPaths -join "; "
        Write-Warn "$($promptPaths.Count) synthesis prompt(s) require processing."
        Send-LocalNotification "YouTube knowledge vault: synthesis is pending and Claude execution was skipped."
    } else {
        $stage = "SYNTHESIS"
        $promptPath = $promptPaths -join "; "

        $promptNumber = 0

        foreach ($currentPromptPath in $promptPaths) {
            $promptNumber++

            Write-Info (
                "Stage 2/3 - running Claude Code unattended " +
                "($promptNumber/$($promptPaths.Count))..."
            )
            Write-Host "Prompt: $currentPromptPath"

            $promptText = Get-Content -LiteralPath $currentPromptPath -Raw
            $promptStamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $currentClaudeOutputPath = Join-Path `
                $reportsDir `
                "claude_weekly_synthesis_${promptStamp}_${promptNumber}.json"

            Push-Location $VaultRoot
            try {
                $claudeResult = $promptText | & claude -p `
                    --permission-mode acceptEdits `
                    --effort $ClaudeEffort `
                    --max-budget-usd $MaxClaudeBudgetUsd `
                    --output-format json `
                    --no-session-persistence
                $claudeExit = $LASTEXITCODE
            } finally {
                Pop-Location
            }

            $claudeResult |
                Set-Content -LiteralPath $currentClaudeOutputPath -Encoding UTF8

            $claudeOutputPath = $currentClaudeOutputPath

            if ($claudeExit -ne 0) {
                throw (
                    "Claude synthesis failed with exit code $claudeExit. " +
                    "See $currentClaudeOutputPath"
                )
            }

            $stage = "POST-SYNTHESIS QA"
            Write-Info (
                "Stage 3/3 - reconciling and validating synthesis " +
                "($promptNumber/$($promptPaths.Count))..."
            )

            & pwsh -NoProfile -ExecutionPolicy Bypass `
                -File $postPath `
                -VaultRoot $VaultRoot `
                -Apply

            $postExit = $LASTEXITCODE

            if ($postExit -ne 0) {
                throw (
                    "Post-synthesis completion check returned exit code " +
                    "$postExit. Review $latestPostPath"
                )
            }

            if (Test-Path -LiteralPath $latestPostPath) {
                $postSynthesisReportPath = $latestPostPath
            }
        }

        # Never report success while manifest rows remain pending.
        $remainingRows = @(Import-Csv -LiteralPath $manifestPath)
        $remainingPending = @(
            $remainingRows |
                Where-Object {
                ([string]$_.synthesis_status).Trim().ToLowerInvariant() -eq "pending" -and
                ([string]$_.transcript_status).Trim().ToLowerInvariant() -eq "downloaded" -and
                ([string]$_.clean_status).Trim().ToLowerInvariant() -eq "clean_ready" -and
                ([string]$_.source_status).Trim().ToLowerInvariant() -eq "source_created"
            }
        )

        if ($remainingPending.Count -gt 0) {
            $remainingIds = @(
                $remainingPending |
                    ForEach-Object { ([string]$_.video_id).Trim() }
            )

            throw (
                "Synthesis finished but pending manifest rows remain: " +
                ($remainingIds -join ", ")
            )
        }

        $status = "SUCCESS - BATCH COMPLETE"
        $stage = "COMPLETE"
        $exitCode = 0
        Write-Ok "Weekly agentic pipeline complete."
        Send-LocalNotification "YouTube knowledge vault: synthesis and QA completed successfully."
    }
} catch {
    $errorMessage = $_.Exception.Message
    $status = "FAILED"
    Write-Host "ERROR: $errorMessage" -ForegroundColor Red
    Send-LocalNotification "YouTube knowledge vault pipeline failed at $stage. Review latest_weekly_agentic_pipeline.md."
} finally {
    $finishedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($reportsDir -and (Test-Path -LiteralPath $reportsDir)) {
        Write-PipelineReport `
            -Path $reportPath `
            -LatestPath $latestReportPath `
            -Status $status `
            -StartedAt $startedAt `
            -FinishedAt $finishedAt `
            -Stage $stage `
            -NewVideos $newVideos `
            -SynthesisRequired $synthesisRequired `
            -PromptPath $promptPath `
            -ClaudeOutputPath $(if (Test-Path -LiteralPath $claudeOutputPath) { $claudeOutputPath } else { '' }) `
            -PostSynthesisReportPath $postSynthesisReportPath `
            -ErrorMessage $errorMessage

        Write-Host "Pipeline report: $reportPath"
        Write-Host "Latest status:  $latestReportPath"
    }
}

exit $exitCode
