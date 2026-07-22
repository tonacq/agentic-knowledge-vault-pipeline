<#
.SYNOPSIS
  Weekly updater v8 for a one-channel YouTube LLM wiki / Obsidian vault.

.DESCRIPTION
  Version: 8
  Status: Development candidate
  Supersedes: weekly_update_channel_wiki_v7.ps1

  This is the Stage 1 upkeep agent.

  It scans a configured YouTube channel with yt-dlp, compares video IDs against
  data/manifest.csv, downloads transcripts only for newly discovered videos,
  cleans those transcripts, creates source pages, updates manifest state, and
  generates a Claude Code synthesis prompt for the new source pages.

  Version 8 retains the v7 latest-run status and failure handling, and avoids
  rewriting or backing up data/manifest.csv when no new videos are detected.

  It intentionally does NOT run synthesis and does NOT reprocess the full vault.

.REQUIREMENTS
  - PowerShell 5.1+
  - yt-dlp available on PATH, or pass -YtDlpPath
  - Run from the vault root, or pass -VaultRoot

.EXAMPLES
  Report-only scan:
    powershell -ExecutionPolicy Bypass -File ".\scripts\weekly_update_channel_wiki_v8.ps1" -ReportOnly

  Apply update:
    powershell -ExecutionPolicy Bypass -File ".\scripts\weekly_update_channel_wiki_v8.ps1" -Apply

  Apply with explicit channel URL:
    powershell -ExecutionPolicy Bypass -File ".\scripts\weekly_update_channel_wiki_v8.ps1" -Apply -ChannelUrl "https://www.youtube.com/@example/videos"

  One-off prune of existing duplicate VTT variants in raw/:
    powershell -ExecutionPolicy Bypass -File ".\scripts\weekly_update_channel_wiki_v8.ps1" -Apply -PruneExistingDuplicateVttVariants
#>

param(
    [string]$VaultRoot = (Get-Location).Path,
    [string]$ConfigPath = "",
    [string]$ChannelUrl = "",
    [string]$Creator = "",
    [string]$CreatorPage = "",
    [string]$YtDlpPath = "",
    [Nullable[int]]$MaxVideos,
    [string]$Proxy = "",
    [string]$CookieFile = "",
    [string]$JsRuntime = "",
    [switch]$ReportOnly,
    [switch]$Apply,
    [switch]$SkipTranscriptDownload,
    [switch]$SkipGitCommit,
    [switch]$KeepDuplicateVttVariants,
    [switch]$PruneExistingDuplicateVttVariants
)

$ErrorActionPreference = "Stop"

$VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $VaultRoot "config/vault.json"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Runtime configuration not found: $ConfigPath. Copy config/vault.example.json to config/vault.json and configure it."
}

try {
    $runtimeConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "Runtime configuration is not valid JSON: $ConfigPath. $($_.Exception.Message)"
}

if ([string]::IsNullOrWhiteSpace($ChannelUrl)) { $ChannelUrl = [string]$runtimeConfig.channel_url }
if ([string]::IsNullOrWhiteSpace($Creator)) { $Creator = [string]$runtimeConfig.creator }
if ([string]::IsNullOrWhiteSpace($CreatorPage)) { $CreatorPage = [string]$runtimeConfig.creator_page }
if ([string]::IsNullOrWhiteSpace($YtDlpPath)) { $YtDlpPath = [string]$runtimeConfig.yt_dlp_path }
if (-not $MaxVideos.HasValue) { $MaxVideos = [int]$runtimeConfig.max_videos }
if ([string]::IsNullOrWhiteSpace($Proxy)) { $Proxy = [string]$runtimeConfig.proxy }
if ([string]::IsNullOrWhiteSpace($CookieFile)) { $CookieFile = [string]$runtimeConfig.cookie_file }
if ([string]::IsNullOrWhiteSpace($JsRuntime)) { $JsRuntime = [string]$runtimeConfig.js_runtime }

if ([string]::IsNullOrWhiteSpace($ChannelUrl)) { throw "channel_url is required in $ConfigPath." }
if ([string]::IsNullOrWhiteSpace($Creator)) { throw "creator is required in $ConfigPath." }
if ([string]::IsNullOrWhiteSpace($CreatorPage)) { $CreatorPage = Slugify $Creator }
if ([string]::IsNullOrWhiteSpace($YtDlpPath)) { $YtDlpPath = "yt-dlp" }

if ($Apply -and $ReportOnly) {
    throw "Use either -Apply or -ReportOnly, not both."
}

if (-not $Apply -and -not $ReportOnly) {
    $ReportOnly = $true
}

# -----------------------------
# Helpers
# -----------------------------

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }

function Write-LatestRunStatus(
    [string]$Path,
    [string]$RunStatus,
    [string]$Mode,
    [string]$StartedAt,
    [string]$FinishedAt,
    [int]$ScannedCount,
    [int]$NewVideoCount,
    [int]$DownloadedCount,
    [int]$SourceCount,
    [int]$MissingCount,
    [bool]$SynthesisRequired,
    [string]$PromptPath,
    [string]$ReportPath,
    [string]$ErrorMessage
) {
    $promptDisplay = if ([string]::IsNullOrWhiteSpace($PromptPath)) { "none" } else { $PromptPath }
    $reportDisplay = if ([string]::IsNullOrWhiteSpace($ReportPath)) { "none" } else { $ReportPath }
    $errorDisplay = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { "none" } else { $ErrorMessage -replace "`r?`n", " " }
    $synthesisDisplay = if ($SynthesisRequired) { "YES" } else { "NO" }

    $lines = @(
        "# Latest Weekly Wiki Update",
        "",
        "- Run status: **$RunStatus**",
        "- Mode: $Mode",
        "- Started: $StartedAt",
        "- Finished: $FinishedAt",
        "- Videos scanned: $ScannedCount",
        "- New videos found: $NewVideoCount",
        "- Transcripts downloaded: $DownloadedCount",
        "- Source pages created/found: $SourceCount",
        "- Missing/failed transcripts: $MissingCount",
        "- Synthesis required: **$synthesisDisplay**",
        "- Prompt generated: $promptDisplay",
        "- Detailed report: $reportDisplay",
        "- Error: $errorDisplay"
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $tempPath = "$Path.tmp"
    Set-Content -LiteralPath $tempPath -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-RelativePath([string]$Root, [string]$Path) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootUri = New-Object System.Uri($rootFull)
    $pathUri = New-Object System.Uri($pathFull)
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Get-Field($Row, [string]$Name) {
    if ($Row.PSObject.Properties.Name -contains $Name) {
        return [string]$Row.$Name
    }
    return ""
}

function Set-Field($Row, [string]$Name, [string]$Value) {
    if ($Row.PSObject.Properties.Name -contains $Name) {
        $Row.$Name = $Value
    } else {
        $Row | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Ensure-Columns($Rows, [string[]]$Columns) {
    foreach ($row in $Rows) {
        foreach ($col in $Columns) {
            if (-not ($row.PSObject.Properties.Name -contains $col)) {
                $row | Add-Member -NotePropertyName $col -NotePropertyValue ""
            }
        }
    }
}

function Escape-YamlDoubleQuoted([string]$Text) {
    if ($null -eq $Text) { return "" }
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Escape-MarkdownTableCell([string]$Text) {
    if ($null -eq $Text) { return "" }
    return ($Text -replace '\|', '\|' -replace "`r?`n", " ").Trim()
}

function Slugify([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "untitled" }
    $slug = $Text.ToLowerInvariant()
    $slug = $slug -replace '[^\p{L}\p{Nd}]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 90) { $slug = $slug.Substring(0, 90).Trim('-') }
    if ([string]::IsNullOrWhiteSpace($slug)) { return "untitled" }
    return $slug
}

function Normalize-UploadDate([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $v = $Value.Trim()
    if ($v -match '^\d{4}-\d{2}-\d{2}$') { return $v }
    if ($v -match '^(\d{4})(\d{2})(\d{2})$') { return "$($Matches[1])-$($Matches[2])-$($Matches[3])" }
    return $v
}

function Convert-VttToPlainText([string]$VttPath, [string]$OutPath) {
    $lines = Get-Content -LiteralPath $VttPath -Encoding UTF8
    $clean = New-Object System.Collections.Generic.List[string]
    $prev = ""

    foreach ($line in $lines) {
        $s = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -eq "WEBVTT") { continue }
        if ($s.StartsWith("Kind:")) { continue }
        if ($s.StartsWith("Language:")) { continue }
        if ($s -match "-->") { continue }
        if ($s -match "^\d+$") { continue }

        $s = [regex]::Replace($s, "<[^>]+>", "")
        $s = $s -replace "&amp;", "&"
        $s = $s -replace "&lt;", "<"
        $s = $s -replace "&gt;", ">"
        $s = $s -replace "&quot;", '"'
        $s = $s -replace "&#39;", "'"
        $s = [regex]::Replace($s, "\s+", " ").Trim()

        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -eq $prev) { continue }
        $clean.Add($s)
        $prev = $s
    }

    $text = ($clean -join " ")
    Set-Content -LiteralPath $OutPath -Value $text -Encoding UTF8
}

function Invoke-YtDlpJsonLines([string[]]$Arguments) {
    $output = & $YtDlpPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $items = New-Object System.Collections.Generic.List[object]
    $messages = New-Object System.Collections.Generic.List[string]

    foreach ($line in $output) {
        $s = [string]$line
        if ($s.TrimStart().StartsWith("{")) {
            try {
                $items.Add(($s | ConvertFrom-Json))
            } catch {
                $messages.Add($s)
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($s)) {
            $messages.Add($s)
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Items    = @($items.ToArray())
        Messages = @($messages.ToArray())
    }
}

function Get-VideoIdFromEntry($Entry) {
    $id = [string]$Entry.id
    if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }

    $url = [string]$Entry.url
    if ($url -match '^[A-Za-z0-9_-]{11}$') { return $url }
    if ($url -match 'v=([A-Za-z0-9_-]{11})') { return $Matches[1] }
    if ($url -match '/shorts/([A-Za-z0-9_-]{11})') { return $Matches[1] }
    if ($url -match 'youtu\.be/([A-Za-z0-9_-]{11})') { return $Matches[1] }

    return ""
}

function Get-VideoUrlFromEntry($Entry, [string]$VideoId) {
    $webUrl = [string]$Entry.webpage_url
    if (-not [string]::IsNullOrWhiteSpace($webUrl)) { return $webUrl }

    $url = [string]$Entry.url
    if ($url -match '^https?://') { return $url }

    if (-not [string]::IsNullOrWhiteSpace($VideoId)) {
        return "https://www.youtube.com/watch?v=$VideoId"
    }

    return $url
}

function Get-RawTranscriptCandidatesForVideo([string]$RawDir, [string]$VideoId) {
    return @(Get-ChildItem -LiteralPath $RawDir -File -Filter "*.vtt" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$VideoId*" } |
        Sort-Object LastWriteTime -Descending)
}

function Find-RawTranscriptForVideo([string]$RawDir, [string]$VideoId) {
    $matches = @(Get-RawTranscriptCandidatesForVideo -RawDir $RawDir -VideoId $VideoId)

    if ($matches.Count -eq 0) { return $null }

    # Canonical transcript rule for this vault:
    #   1. Prefer YouTube's original English auto-caption file: *.en-orig.vtt
    #   2. Fall back to normalized English: *.en.vtt
    #   3. Fall back to English locale variants: *.en-*.vtt
    #   4. Fall back to the newest VTT only if no English-labelled file exists.
    $preferred = $matches | Where-Object { $_.Name -like "*.en-orig.vtt" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($preferred) { return $preferred.FullName }

    $english = $matches | Where-Object { $_.Name -like "*.en.vtt" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($english) { return $english.FullName }

    $englishLocale = $matches | Where-Object { $_.Name -like "*.en-*.vtt" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($englishLocale) { return $englishLocale.FullName }

    return ($matches | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Remove-DuplicateRawTranscriptVariants([string]$RawDir, [string]$VideoId, [string]$CanonicalPath) {
    if ([string]::IsNullOrWhiteSpace($CanonicalPath)) { return 0 }
    $canonicalFull = [System.IO.Path]::GetFullPath($CanonicalPath)
    $matches = @(Get-RawTranscriptCandidatesForVideo -RawDir $RawDir -VideoId $VideoId)
    $removed = 0

    foreach ($m in $matches) {
        $candidateFull = [System.IO.Path]::GetFullPath($m.FullName)
        if ($candidateFull -ne $canonicalFull) {
            Remove-Item -LiteralPath $candidateFull -Force
            $removed++
        }
    }

    return $removed
}

function Find-InfoJsonForVideo([string]$RawDir, [string]$VideoId) {
    $match = Get-ChildItem -LiteralPath $RawDir -File -Filter "*.info.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$VideoId*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($match) { return $match.FullName }
    return $null
}

function New-ManifestRow([string[]]$Columns, $Entry, [string]$DefaultChannel, [string]$Today) {
    $videoId = Get-VideoIdFromEntry -Entry $Entry
    $title = [string]$Entry.title
    $url = Get-VideoUrlFromEntry -Entry $Entry -VideoId $videoId
    $channel = [string]$Entry.channel
    if ([string]::IsNullOrWhiteSpace($channel)) { $channel = $DefaultChannel }
    $uploadDate = Normalize-UploadDate ([string]$Entry.upload_date)

    $obj = [ordered]@{}
    foreach ($col in $Columns) { $obj[$col] = "" }

    $obj["video_id"] = $videoId
    $obj["title"] = $title
    $obj["url"] = $url
    $obj["channel"] = $channel
    $obj["upload_date"] = $uploadDate
    $obj["transcript_status"] = "discovered"
    $obj["ingest_status"] = "pending"
    $obj["date_discovered"] = $Today
    $obj["last_checked"] = $Today
    $obj["notes"] = "discovered_by_weekly_updater"
    $obj["clean_status"] = "pending"
    $obj["source_status"] = "pending"
    $obj["synthesis_status"] = "pending"

    return [pscustomobject]$obj
}

function Update-MetadataFromInfoJson($Row, [string]$InfoJsonPath) {
    if (-not $InfoJsonPath -or -not (Test-Path -LiteralPath $InfoJsonPath)) { return }

    try {
        $info = Get-Content -LiteralPath $InfoJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$info.title)) { Set-Field $Row "title" ([string]$info.title) }
        if (-not [string]::IsNullOrWhiteSpace([string]$info.channel)) { Set-Field $Row "channel" ([string]$info.channel) }
        if (-not [string]::IsNullOrWhiteSpace([string]$info.upload_date)) { Set-Field $Row "upload_date" (Normalize-UploadDate ([string]$info.upload_date)) }
        if (-not [string]::IsNullOrWhiteSpace([string]$info.webpage_url)) { Set-Field $Row "url" ([string]$info.webpage_url) }
    } catch {
        # Keep existing manifest data if info JSON cannot be parsed.
    }
}

function Create-SourcePageForRow($Row, [string]$CleanPath, [string]$SourcesDir, [string]$Today) {
    $videoId = Get-Field $Row "video_id"
    $title = Get-Field $Row "title"
    $url = Get-Field $Row "url"
    $uploadDate = Get-Field $Row "upload_date"

    $slug = Slugify $title
    $datePart = $uploadDate
    if ([string]::IsNullOrWhiteSpace($datePart)) { $datePart = "undated" }

    $fileName = "$datePart`_$videoId`_$slug.md"
    $sourcePath = Join-Path $SourcesDir $fileName

    if (Test-Path -LiteralPath $sourcePath) {
        Set-Field $Row "source_status" "source_exists"
        Set-Field $Row "source_file" (Get-RelativePath -Root $VaultRoot -Path $sourcePath)
        if ([string]::IsNullOrWhiteSpace((Get-Field $Row "source_created"))) { Set-Field $Row "source_created" $Today }
        return $sourcePath
    }

    $transcript = Get-Content -LiteralPath $CleanPath -Raw -Encoding UTF8
    $relativeClean = Get-RelativePath -Root $VaultRoot -Path $CleanPath
    $safeTitle = Escape-YamlDoubleQuoted $title

    $note = @"
---
type: source
creator: $Creator
video_id: "$videoId"
title: "$safeTitle"
url: "$url"
upload_date: "$uploadDate"
clean_transcript_file: "$relativeClean"
source_status: "mechanically_created"
synthesis_status: "pending"
created: "$Today"
---

# $title

## Metadata

- Creator: [[$CreatorPage]]
- Video ID: ``$videoId``
- Upload date: $uploadDate
- URL: $url
- Clean transcript: ``$relativeClean``
- Source creation method: weekly updater mechanical transcript import
- Synthesis status: pending

## Working Notes

This source page was created mechanically from the clean transcript by the weekly upkeep updater.

It has not yet been synthesised by Claude Code into tools, workflows, prompts, concepts, or implementation notes.

## Transcript

$transcript
"@

    Set-Content -LiteralPath $sourcePath -Value $note -Encoding UTF8

    Set-Field $Row "source_status" "source_created"
    Set-Field $Row "source_file" (Get-RelativePath -Root $VaultRoot -Path $sourcePath)
    Set-Field $Row "source_created" $Today
    return $sourcePath
}

function Write-WeeklyReport([string]$ReportPath, [string]$CsvPath, [object[]]$Events, [string]$PromptPath, [string]$Mode, [string]$ChannelUrl, [int]$ScannedCount) {
    $newCount = @($Events | Where-Object { $_.Status -eq "new" }).Count
    $createdSources = @($Events | Where-Object { $_.SourceStatus -in @("source_created", "source_exists") }).Count
    $downloaded = @($Events | Where-Object { $_.TranscriptStatus -eq "downloaded" }).Count
    $missing = @($Events | Where-Object { $_.TranscriptStatus -like "missing*" -or $_.TranscriptStatus -like "failed*" }).Count
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("---")
    $lines.Add("type: report")
    $lines.Add("report_type: weekly_youtube_wiki_update")
    $lines.Add("created: $(Get-Date -Format 'yyyy-MM-dd')")
    $lines.Add("mode: $Mode")
    $lines.Add("---")
    $lines.Add("")
    $lines.Add("# Weekly YouTube LLM Wiki Update")
    $lines.Add("")
    $lines.Add("Generated: $timestamp")
    $lines.Add("")
    $lines.Add("## Summary")
    $lines.Add("")
    $lines.Add("- Mode: **$Mode**")
    $lines.Add("- Channel URL: $ChannelUrl")
    $lines.Add("- Channel items scanned: $ScannedCount")
    $lines.Add("- New videos detected: $newCount")
    $lines.Add("- Transcripts downloaded: $downloaded")
    $lines.Add("- Source pages created/found: $createdSources")
    $lines.Add("- Missing/failed transcripts: $missing")
    if (-not [string]::IsNullOrWhiteSpace($PromptPath)) {
        $relPromptInline = Get-RelativePath -Root $VaultRoot -Path $PromptPath
        $lines.Add(("- Claude Code synthesis prompt: {0}" -f $relPromptInline))
    } else {
        $lines.Add("- Claude Code synthesis prompt: none")
    }
    $lines.Add("")
    $lines.Add("## New video details")
    $lines.Add("")

    if ($Events.Count -eq 0) {
        $lines.Add("No new videos detected.")
    } else {
        $lines.Add("| Video ID | Upload date | Title | Transcript | Source | Notes |")
        $lines.Add("|---|---:|---|---|---|---|")
        foreach ($e in $Events) {
            $lines.Add("| $(Escape-MarkdownTableCell $e.VideoId) | $(Escape-MarkdownTableCell $e.UploadDate) | $(Escape-MarkdownTableCell $e.Title) | $(Escape-MarkdownTableCell $e.TranscriptStatus) | $(Escape-MarkdownTableCell $e.SourceStatus) | $(Escape-MarkdownTableCell $e.Notes) |")
        }
    }

    $lines.Add("")
    $lines.Add("## Next action")
    $lines.Add("")
    if ($newCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($PromptPath)) {
        $relPrompt = Get-RelativePath -Root $VaultRoot -Path $PromptPath
        $lines.Add("Run Claude Code against the generated prompt:")
        $lines.Add("")
        $lines.Add("~~~~text")
        $lines.Add("Read $relPrompt and perform the weekly synthesis update exactly as instructed.")
        $lines.Add("~~~~")
    } else {
        $lines.Add("No synthesis action required.")
    }

    Set-Content -LiteralPath $ReportPath -Value $lines -Encoding UTF8

    if ($Events.Count -gt 0) {
        $Events | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    } else {
        @([pscustomobject]@{ Status = "none"; Notes = "No new videos detected" }) | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    }
}

function Write-SynthesisPrompt([string]$PromptPath, [object[]]$Events, [string]$ReportPath, [string]$Today) {
    $sourceEvents = @($Events | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SourceFile) })
    if ($sourceEvents.Count -eq 0) { return $null }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Weekly Synthesis Prompt - $Today")
    $lines.Add("")
    $lines.Add("You are working inside the configured YouTube knowledge-vault Obsidian workspace.")
    $lines.Add("")
    $lines.Add("## Task")
    $lines.Add("")
    $lines.Add("Synthesize **only** the newly added source pages listed below into the existing wiki.")
    $lines.Add("")
    $lines.Add("Do not reprocess the full vault.")
    $lines.Add("Do not edit raw transcripts.")
    $lines.Add("Do not edit clean transcripts.")
    $lines.Add("Do not overwrite existing source pages.")
    $lines.Add("")
    $lines.Add("## Read first")
    $lines.Add("")
    $lines.Add("- data/manifest.csv")
    $lines.Add("- wiki/synthesis/synthesis_register.md")
    $relReport = Get-RelativePath -Root $VaultRoot -Path $ReportPath
    $lines.Add(("- {0}" -f $relReport))
    $lines.Add("")
    $lines.Add("## New source pages")
    $lines.Add("")
    foreach ($e in $sourceEvents) {
        $lines.Add(("- {0} - {1}" -f $e.SourceFile, $e.Title))
    }
    $lines.Add("")
    $lines.Add("## Update targets")
    $lines.Add("")
    $lines.Add("Update only the relevant pages in:")
    $lines.Add("")
    $lines.Add("- wiki/tools/")
    $lines.Add("- wiki/concepts/")
    $lines.Add("- wiki/workflows/")
    $lines.Add("- wiki/prompts/")
    $lines.Add("- wiki/synthesis/")
    $lines.Add("- wiki/synthesis/synthesis_register.md")
    $lines.Add("")
    $lines.Add("## Process")
    $lines.Add("")
    $lines.Add("For each new source page:")
    $lines.Add("")
    $lines.Add("1. Identify tools mentioned.")
    $lines.Add("2. Identify concepts and mental models.")
    $lines.Add("3. Identify workflows and implementation patterns.")
    $lines.Add("4. Identify business/practical lessons.")
    $lines.Add("5. Link to existing wiki pages where possible.")
    $lines.Add("6. Create new pages only where a genuinely new concept/tool/workflow exists.")
    $lines.Add("7. Update data/manifest.csv synthesis fields only for the new rows after synthesis:")
    $lines.Add("   - synthesis_status")
    $lines.Add("   - synthesis_last_checked")
    $lines.Add("   - synthesis_evidence")
    $lines.Add("   - synthesis_batch")
    $lines.Add("")
    $lines.Add("## Output")
    $lines.Add("")
    $lines.Add("Write a synthesis report to:")
    $lines.Add("")
    $lines.Add(("- reports/weekly_synthesis_{0}.md" -f $Today.Replace("-", "")))
    $lines.Add("")
    $lines.Add("Include:")
    $lines.Add("")
    $lines.Add("- new concepts/tools/workflows found")
    $lines.Add("- pages updated")
    $lines.Add("- pages created")
    $lines.Add("- claims that need human review")
    $lines.Add("- recommended next learning actions for Tony")

    Set-Content -LiteralPath $PromptPath -Value $lines -Encoding UTF8
    return $PromptPath
}

# -----------------------------
# Paths and setup
# -----------------------------

$runStartedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runStatus = "FAILED"
$runError = ""
$latestStatusPath = ""
$latestScannedCount = 0
$latestNewVideoCount = 0
$latestDownloadedCount = 0
$latestSourceCount = 0
$latestMissingCount = 0
$latestSynthesisRequired = $false
$latestPromptRelative = ""
$latestReportRelative = ""

try {
$VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
$ManifestPath = Join-Path $VaultRoot (Join-Path "data" "manifest.csv")
$RawDir = Join-Path $VaultRoot "raw"
$CleanDir = Join-Path $VaultRoot (Join-Path "data" "clean_transcripts")
$SourcesDir = Join-Path $VaultRoot (Join-Path "wiki" "sources")
$ReportsDir = Join-Path $VaultRoot "reports"
$PromptsDir = Join-Path $VaultRoot "prompts"
$latestStatusPath = Join-Path $ReportsDir "latest_weekly_update.md"

if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
Ensure-Directory $RawDir
Ensure-Directory $CleanDir
Ensure-Directory $SourcesDir
Ensure-Directory $ReportsDir
Ensure-Directory $PromptsDir

$today = Get-Date -Format "yyyy-MM-dd"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$mode = if ($Apply) { "APPLY" } else { "REPORT ONLY" }
$reportPath = Join-Path $ReportsDir "weekly_update_$stamp.md"
$csvPath = Join-Path $ReportsDir "weekly_update_$stamp.csv"
$promptPath = Join-Path $PromptsDir "weekly_synthesis_$stamp.md"

Write-Info "Weekly YouTube LLM Wiki updater"
Write-Host "Vault:      $VaultRoot"
Write-Host "Channel:    $ChannelUrl"
Write-Host "Mode:       $mode"
Write-Host "Max videos: $MaxVideos"
Write-Host "Canonical VTT: prefer .en-orig.vtt; fallback .en.vtt"
Write-Host ""

# -----------------------------
# Load manifest
# -----------------------------

$rows = @(Import-Csv -LiteralPath $ManifestPath)

$requiredColumns = @(
    "video_id",
    "title",
    "url",
    "channel",
    "upload_date",
    "transcript_file",
    "transcript_status",
    "ingest_status",
    "date_discovered",
    "date_downloaded",
    "date_ingested",
    "last_checked",
    "notes",
    "clean_status",
    "clean_transcript_file",
    "source_status",
    "source_file",
    "source_created",
    "synthesis_status",
    "synthesis_last_checked",
    "synthesis_evidence",
    "synthesis_batch"
)
$columns = $requiredColumns
if ($rows.Count -gt 0) {
    Ensure-Columns -Rows $rows -Columns $requiredColumns
    $columns = @($rows[0].PSObject.Properties.Name)
}

$existingById = @{}
foreach ($r in $rows) {
    $id = Get-Field $r "video_id"
    if (-not [string]::IsNullOrWhiteSpace($id)) { $existingById[$id] = $r }
}

$defaultChannel = if ($rows.Count -gt 0) { Get-Field $rows[0] "channel" } else { $Creator }

if ($Apply -and $PruneExistingDuplicateVttVariants -and -not $KeepDuplicateVttVariants) {
    Write-Info "Pruning existing duplicate VTT variants in raw/ using canonical transcript rule..."
    $totalPruned = 0
    foreach ($r in $rows) {
        $id = Get-Field $r "video_id"
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $canonical = Find-RawTranscriptForVideo -RawDir $RawDir -VideoId $id
        if ($canonical) {
            $totalPruned += Remove-DuplicateRawTranscriptVariants -RawDir $RawDir -VideoId $id -CanonicalPath $canonical
        }
    }
    Write-Host "Existing duplicate VTT files pruned: $totalPruned"
}

# -----------------------------
# Scan channel
# -----------------------------

Write-Info "Scanning channel with yt-dlp..."
$scanArgs = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
    $scanArgs.Add("--proxy")
    $scanArgs.Add($Proxy)
}
$scanArgs.Add("--flat-playlist")
$scanArgs.Add("--dump-json")
$scanArgs.Add("--no-warnings")
if ($MaxVideos -gt 0) {
    $scanArgs.Add("--playlist-end")
    $scanArgs.Add([string]$MaxVideos)
}
$scanArgs.Add($ChannelUrl)

$scan = Invoke-YtDlpJsonLines -Arguments $scanArgs.ToArray()
if ($scan.ExitCode -ne 0 -and $scan.Items.Count -eq 0) {
    throw "yt-dlp scan failed. Messages: $($scan.Messages -join '; ')"
}

$entries = @()
foreach ($scanItem in $scan.Items) {
    $entries += $scanItem
}
if ($entries.Count -eq 0) {
    throw "yt-dlp returned no video entries. Check ChannelUrl or yt-dlp installation. Messages: $($scan.Messages -join '; ')"
}

$newRows = New-Object System.Collections.Generic.List[object]
$retryRows = New-Object System.Collections.Generic.List[object]

foreach ($entry in $entries) {
    $videoId = Get-VideoIdFromEntry -Entry $entry
    if ([string]::IsNullOrWhiteSpace($videoId)) { continue }

    if ($existingById.ContainsKey($videoId)) {
        $existingRow = $existingById[$videoId]
        $existingTranscriptStatus = Get-Field $existingRow "transcript_status"

        if (
            $existingTranscriptStatus -like "missing*" -or
            $existingTranscriptStatus -like "failed*"
        ) {
            $retryRows.Add($existingRow)
        }

        # Healthy existing rows remain untouched.
        continue
    }

    $newRow = New-ManifestRow -Columns $columns -Entry $entry -DefaultChannel $defaultChannel -Today $today
    $newRows.Add($newRow)
}

Write-Host "Scanned entries:   $($entries.Count)"
Write-Host "New video IDs:     $($newRows.Count)"
Write-Host "Transcript retries:$($retryRows.Count)"
Write-Host ""
$latestScannedCount = $entries.Count
$latestNewVideoCount = $newRows.Count

$events = New-Object System.Collections.Generic.List[object]
$workRows = @($newRows.ToArray()) + @($retryRows.ToArray())

foreach ($row in $workRows) {
    $isRetry = $existingById.ContainsKey((Get-Field $row "video_id"))
    $eventStatus = if ($isRetry) { "retry" } else { "new" }
    $videoId = Get-Field $row "video_id"
    $title = Get-Field $row "title"
    $url = Get-Field $row "url"
    $uploadDate = Get-Field $row "upload_date"
    $eventNotes = New-Object System.Collections.Generic.List[string]

    if ($ReportOnly) {
        $events.Add([pscustomobject]@{
            Status           = $eventStatus
            VideoId          = $videoId
            UploadDate       = $uploadDate
            Title            = $title
            Url              = $url
            TranscriptStatus = "would_download"
            CleanStatus      = "would_clean"
            SourceStatus     = "would_create_source"
            SourceFile       = ""
            PromptFile       = ""
            Notes            = "report_only"
        })
        continue
    }

    # Apply mode from here.
    Set-Field $row "date_discovered" $today
    Set-Field $row "last_checked" $today

    $rawTranscriptPath = $null
    if (-not $SkipTranscriptDownload) {
        Write-Info "Downloading transcript for $videoId - $title"
        $downloadArgs = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
            $downloadArgs.Add("--proxy")
            $downloadArgs.Add($Proxy)
        }
        $downloadArgs.AddRange([string[]]@(
            "--skip-download",
            "--remote-components", "ejs:github",
            "--write-auto-subs",
            # Ask for both variants so fallback works, then keep only one canonical VTT.
            # Canonical rule: prefer .en-orig.vtt, else fall back to .en.vtt.
            "--sub-langs", "en-orig,en",
            "--sub-format", "vtt",
            "--write-info-json",
            "--no-overwrites",
            "--paths", $RawDir,
            "-o", "%(upload_date)s_youtube_%(channel)s_%(title).160B_%(id)s.%(ext)s",
            $url
        ))

        if (-not [string]::IsNullOrWhiteSpace($CookieFile)) {
            $downloadArgs.Insert(1, "--cookies")
            $downloadArgs.Insert(2, $CookieFile)
        }
        if (-not [string]::IsNullOrWhiteSpace($JsRuntime)) {
            $downloadArgs.Insert(1, "--js-runtimes")
            $downloadArgs.Insert(2, $JsRuntime)
        }

        $downloadOutput = & $YtDlpPath @($downloadArgs.ToArray()) 2>&1
        $downloadExit = $LASTEXITCODE
        if ($downloadExit -ne 0) {
            $eventNotes.Add("yt-dlp_download_exit_$downloadExit")
        }
    } else {
        $eventNotes.Add("transcript_download_skipped")
    }

    $infoJson = Find-InfoJsonForVideo -RawDir $RawDir -VideoId $videoId
    if ($infoJson) { Update-MetadataFromInfoJson -Row $row -InfoJsonPath $infoJson }

    $title = Get-Field $row "title"
    $uploadDate = Get-Field $row "upload_date"
    $rawTranscriptPath = Find-RawTranscriptForVideo -RawDir $RawDir -VideoId $videoId

    if ($rawTranscriptPath) {
        $rawLeaf = Split-Path $rawTranscriptPath -Leaf
        Set-Field $row "transcript_file" $rawLeaf
        Set-Field $row "transcript_status" "downloaded"
        Set-Field $row "date_downloaded" $today
        if ($rawLeaf -like "*.en-orig.vtt") { $eventNotes.Add("canonical .en-orig.vtt selected") }
        elseif ($rawLeaf -like "*.en.vtt") { $eventNotes.Add("fallback .en.vtt selected") }
        else { $eventNotes.Add("nonstandard_vtt_fallback") }

        if (-not $KeepDuplicateVttVariants) {
            $removedVttCount = Remove-DuplicateRawTranscriptVariants -RawDir $RawDir -VideoId $videoId -CanonicalPath $rawTranscriptPath
            if ($removedVttCount -gt 0) { $eventNotes.Add("removed_duplicate_vtt_variants_$removedVttCount") }
        } else {
            $eventNotes.Add("duplicate_vtt_variants_kept")
        }

        $cleanBase = [System.IO.Path]::GetFileNameWithoutExtension($rawLeaf)
        $cleanPath = Join-Path $CleanDir "$cleanBase.txt"
        Convert-VttToPlainText -VttPath $rawTranscriptPath -OutPath $cleanPath

        Set-Field $row "clean_status" "clean_ready"
        Set-Field $row "clean_transcript_file" (Get-RelativePath -Root $VaultRoot -Path $cleanPath)

        $sourcePath = Create-SourcePageForRow -Row $row -CleanPath $cleanPath -SourcesDir $SourcesDir -Today $today
        Set-Field $row "ingest_status" "pending"
        if ([string]::IsNullOrWhiteSpace((Get-Field $row "synthesis_status"))) { Set-Field $row "synthesis_status" "pending" }

        $events.Add([pscustomobject]@{
            Status           = $eventStatus
            VideoId          = $videoId
            UploadDate       = Get-Field $row "upload_date"
            Title            = Get-Field $row "title"
            Url              = Get-Field $row "url"
            TranscriptStatus = Get-Field $row "transcript_status"
            CleanStatus      = Get-Field $row "clean_status"
            SourceStatus     = Get-Field $row "source_status"
            SourceFile       = Get-Field $row "source_file"
            PromptFile       = ""
            Notes            = ($eventNotes -join "; ")
        })
    } else {
        Set-Field $row "transcript_status" "missing_transcript"
        Set-Field $row "clean_status" "blocked_missing_transcript"
        Set-Field $row "source_status" "blocked_missing_clean_transcript"
        Set-Field $row "synthesis_status" "pending"
        $eventNotes.Add("no_vtt_found_after_download")

        $events.Add([pscustomobject]@{
            Status           = $eventStatus
            VideoId          = $videoId
            UploadDate       = Get-Field $row "upload_date"
            Title            = Get-Field $row "title"
            Url              = Get-Field $row "url"
            TranscriptStatus = Get-Field $row "transcript_status"
            CleanStatus      = Get-Field $row "clean_status"
            SourceStatus     = Get-Field $row "source_status"
            SourceFile       = ""
            PromptFile       = ""
            Notes            = ($eventNotes -join "; ")
        })
    }

    if (-not $isRetry) {
        $rows += $row
    }
}

# -----------------------------
# Write manifest, reports, prompt, git commit
# -----------------------------

$actualPromptPath = $null
if ($Apply -and $events.Count -gt 0) {
    $actualPromptPath = Write-SynthesisPrompt -PromptPath $promptPath -Events @($events.ToArray()) -ReportPath $reportPath -Today $today
    if ($actualPromptPath) {
        foreach ($e in $events) { $e.PromptFile = Get-RelativePath -Root $VaultRoot -Path $actualPromptPath }
    }
}

if ($Apply -and ($newRows.Count -gt 0 -or $retryRows.Count -gt 0)) {
    $manifestBackup = "$ManifestPath.bak_$stamp"
    Copy-Item -LiteralPath $ManifestPath -Destination $manifestBackup -Force
    $rows | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8
    Write-Ok "Manifest updated"
    Write-Host "Manifest backup: $manifestBackup"
} elseif ($Apply) {
    Write-Host "Manifest unchanged: no new videos or transcript retries detected; no backup created"
}

Write-WeeklyReport -ReportPath $reportPath -CsvPath $csvPath -Events @($events.ToArray()) -PromptPath $actualPromptPath -Mode $mode -ChannelUrl $ChannelUrl -ScannedCount $entries.Count

if ($Apply -and -not $SkipGitCommit) {
    $gitDir = Join-Path $VaultRoot ".git"
    if (Test-Path -LiteralPath $gitDir) {
        try {
            Push-Location $VaultRoot
            & git add data/manifest.csv raw data/clean_transcripts wiki/sources prompts reports 2>$null
            $status = (& git status --porcelain)
            if ($status) {
                & git commit -m "Weekly wiki upkeep $today" 2>$null | Out-Null
                Write-Ok "Git commit created: Weekly wiki upkeep $today"
            } else {
                Write-Host "Git: no changes to commit"
            }
        } catch {
            Write-Warn "Git commit skipped/failed: $($_.Exception.Message)"
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "Git: no .git directory found, skipping commit"
    }
}

$eventArray = @($events.ToArray())
$latestDownloadedCount = @($eventArray | Where-Object { $_.TranscriptStatus -eq "downloaded" }).Count
$latestSourceCount = @($eventArray | Where-Object { $_.SourceStatus -in @("source_created", "source_exists") }).Count
$latestMissingCount = @($eventArray | Where-Object { $_.TranscriptStatus -like "missing*" -or $_.TranscriptStatus -like "failed*" }).Count
$latestSynthesisRequired = (-not [string]::IsNullOrWhiteSpace($actualPromptPath))
if ($actualPromptPath) { $latestPromptRelative = Get-RelativePath -Root $VaultRoot -Path $actualPromptPath }
if ($reportPath) { $latestReportRelative = Get-RelativePath -Root $VaultRoot -Path $reportPath }
$runStatus = if ($latestMissingCount -gt 0) { "PARTIAL" } else { "SUCCESS" }

Write-LatestRunStatus `
    -Path $latestStatusPath `
    -RunStatus $runStatus `
    -Mode $mode `
    -StartedAt $runStartedAt `
    -FinishedAt (Get-Date -Format "yyyy-MM-dd HH:mm:ss") `
    -ScannedCount $latestScannedCount `
    -NewVideoCount $latestNewVideoCount `
    -DownloadedCount $latestDownloadedCount `
    -SourceCount $latestSourceCount `
    -MissingCount $latestMissingCount `
    -SynthesisRequired $latestSynthesisRequired `
    -PromptPath $latestPromptRelative `
    -ReportPath $latestReportRelative `
    -ErrorMessage ""

Write-Host ""
Write-Ok "Weekly updater complete"
Write-Host "Mode:                 $mode"
Write-Host "Rows before scan:     $($existingById.Count)"
Write-Host "Channel items scanned:$($entries.Count)"
Write-Host "New videos detected:  $($newRows.Count)"
Write-Host "Transcript retries:   $($retryRows.Count)"
Write-Host "Report:               $reportPath"
Write-Host "CSV:                  $csvPath"
if ($actualPromptPath) { Write-Host "Synthesis prompt:     $actualPromptPath" }
if ($ReportOnly) { Write-Warn "Report-only mode. No manifest, transcript, source page, prompt, or git changes were made." }
Write-Host "Latest status:         $latestStatusPath"
}
catch {
    $runError = $_.Exception.Message

    try {
        if ([string]::IsNullOrWhiteSpace($latestStatusPath)) {
            $safeVaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
            $latestStatusPath = Join-Path $safeVaultRoot (Join-Path "reports" "latest_weekly_update.md")
        }

        Write-LatestRunStatus `
            -Path $latestStatusPath `
            -RunStatus "FAILED" `
            -Mode $(if ($Apply) { "APPLY" } else { "REPORT ONLY" }) `
            -StartedAt $runStartedAt `
            -FinishedAt (Get-Date -Format "yyyy-MM-dd HH:mm:ss") `
            -ScannedCount $latestScannedCount `
            -NewVideoCount $latestNewVideoCount `
            -DownloadedCount $latestDownloadedCount `
            -SourceCount $latestSourceCount `
            -MissingCount $latestMissingCount `
            -SynthesisRequired $false `
            -PromptPath $latestPromptRelative `
            -ReportPath $latestReportRelative `
            -ErrorMessage $runError
    } catch {
        Write-Warn "Could not write latest-run status file: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "Weekly updater FAILED" -ForegroundColor Red
    Write-Host "Error: $runError" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($latestStatusPath)) { Write-Host "Latest status: $latestStatusPath" }
    exit 1
}

exit 0
