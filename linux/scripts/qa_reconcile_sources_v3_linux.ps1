<#
.SYNOPSIS
  QA and reconcile source-page metadata/references for a channel knowledge vault.

.DESCRIPTION
  Report-only by default. Use -Apply to modify source pages.

  Checks/fixes:
    - literal template artefacts such as $videoId and $(Get-RelativePath...)
    - stale source-page text saying synthesis_status: pending when manifest says included
    - source_file / clean_transcript_file existence
    - synthesis_evidence path existence
    - source page metadata consistency against data/manifest.csv

  Optional:
    - Use -UpdateManifestPaths with -Apply to update manifest source_file / clean_transcript_file
      when a file is found by fallback matching.

  Does not call Claude.
  Does not perform synthesis.
  Does not modify raw/ or data/clean_transcripts/.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$VaultRoot = (Get-Location).Path,
    [switch]$Apply,
    [switch]$BackupSourcePages,
    [switch]$UpdateManifestPaths
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }

function Ensure-Directory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-Field($Row, [string]$Name) {
    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Name)) { return "" }
    if ($Row.PSObject.Properties.Name -contains $Name) {
        $value = $Row.$Name
        if ($null -eq $value) { return "" }
        return [string]$value
    }
    return ""
}

function Set-FieldIfPresent($Row, [string]$Name, [string]$Value) {
    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Row.PSObject.Properties.Name -contains $Name) {
        $Row.$Name = $Value
        return $true
    }
    return $false
}

function Normalize-RelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return $Path.Trim().Trim('"').Trim("'").Replace('/', '\')
}

function Resolve-VaultPath([string]$Root, [string]$MaybeRelative) {
    if ([string]::IsNullOrWhiteSpace($MaybeRelative)) { return "" }
    $clean = Normalize-RelativePath $MaybeRelative
    if ([System.IO.Path]::IsPathRooted($clean)) { return $clean }
    return Join-Path $Root $clean
}

function Get-RelativePath([string]$Root, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)

    $rootUri = [System.Uri]::new($rootFull)
    $pathUri = [System.Uri]::new($pathFull)

    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Escape-YamlDoubleQuoted([string]$Text) {
    if ($null -eq $Text) { return "" }

    # YAML double-quoted scalar escaping.
    # Use .Replace rather than -replace to avoid regex escaping surprises.
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Set-Or-AddYamlField([string]$Text, [string]$Field, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Field)) { return $Text }
    if ($null -eq $Text) { return "" }

    $frontMatterPattern = '(?s)^---\s*\r?\n(?<yaml>.*?)\r?\n---'
    $yamlMatch = [regex]::Match($Text, $frontMatterPattern)
    if (-not $yamlMatch.Success) {
        # Deliberately do not create frontmatter from scratch. This script is a reconciler,
        # not a source-page generator.
        return $Text
    }

    $yaml = $yamlMatch.Groups['yaml'].Value
    $quoted = '"' + (Escape-YamlDoubleQuoted $Value) + '"'
    $escapedField = [regex]::Escape($Field)

    if ($yaml -match "(?m)^$escapedField\s*:") {
        $yamlNew = [regex]::Replace(
            $yaml,
            "(?m)^$escapedField\s*:.*$",
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "${Field}: $quoted" }
        )
    } else {
        $yamlNew = $yaml.TrimEnd() + "`r`n${Field}: $quoted"
    }

    return $Text.Substring(0, $yamlMatch.Index) + "---`r`n" + $yamlNew + "`r`n---" + $Text.Substring($yamlMatch.Index + $yamlMatch.Length)
}

function Count-TemplateArtefacts([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }

    $patterns = @(
        '\$videoId',
        '\$title',
        '\$url',
        '\$uploadDate',
        '\$cleanPath',
        '\$sourcePath',
        '\$\(Get-RelativePath[^\)]*\)'
    )

    $count = 0
    foreach ($pattern in $patterns) {
        $count += ([regex]::Matches($Text, $pattern)).Count
    }
    return $count
}

function Convert-ToMarkdownSafe([object]$Value) {
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    $text = $text -replace '\r?\n', ' '
    $text = $text.Replace('|', '\|')
    return $text
}

function Replace-LiteralToken([string]$Text, [string]$Token, [string]$Value) {
    if ($null -eq $Text) { return "" }
    if ($null -eq $Value) { $Value = "" }
    return $Text.Replace($Token, $Value)
}

function Fix-SourceText([string]$Text, $Row, [string]$CleanRel, [string]$SourceRel) {
    $videoId = Get-Field $Row 'video_id'
    $title = Get-Field $Row 'title'
    $url = Get-Field $Row 'url'
    $uploadDate = Get-Field $Row 'upload_date'
    $synthStatus = Get-Field $Row 'synthesis_status'
    $sourceStatus = Get-Field $Row 'source_status'

    if ([string]::IsNullOrWhiteSpace($synthStatus)) { $synthStatus = 'pending' }
    if ([string]::IsNullOrWhiteSpace($sourceStatus)) { $sourceStatus = 'source_exists' }

    $new = $Text

    $new = Replace-LiteralToken $new '$videoId' $videoId
    $new = Replace-LiteralToken $new '$title' $title
    $new = Replace-LiteralToken $new '$url' $url
    $new = Replace-LiteralToken $new '$uploadDate' $uploadDate
    $new = Replace-LiteralToken $new '$cleanPath' $CleanRel
    $new = Replace-LiteralToken $new '$sourcePath' $SourceRel

    # Replace command-substitution artefacts safely. Use a MatchEvaluator so replacement
    # text is not interpreted as a regex replacement pattern.
    if (-not [string]::IsNullOrWhiteSpace($CleanRel)) {
        $new = [regex]::Replace(
            $new,
            '\$\(Get-RelativePath\s+-Root\s+\$VaultRoot\s+-Path\s+\$cleanPath\)',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $CleanRel }
        )
        $new = [regex]::Replace(
            $new,
            '\$\(Get-RelativePath[^\)]*\)',
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $CleanRel }
        )
    }

    # Body status lines. Keep these simple and deterministic.
    $new = [regex]::Replace($new, '(?im)^(\s*-\s*Synthesis status:\s*).+$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $synthStatus })
    $new = [regex]::Replace($new, '(?im)^(\s*Synthesis status:\s*).+$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $synthStatus })

    # Frontmatter and loose YAML-style status lines.
    $new = [regex]::Replace($new, '(?im)^(\s*source_status:\s*).+$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + '"' + $sourceStatus + '"' })
    $new = [regex]::Replace($new, '(?im)^(\s*synthesis_status:\s*).+$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + '"' + $synthStatus + '"' })

    $new = Set-Or-AddYamlField $new 'video_id' $videoId
    $new = Set-Or-AddYamlField $new 'title' $title
    $new = Set-Or-AddYamlField $new 'url' $url
    $new = Set-Or-AddYamlField $new 'upload_date' $uploadDate
    $new = Set-Or-AddYamlField $new 'clean_transcript_file' $CleanRel
    $new = Set-Or-AddYamlField $new 'source_file' $SourceRel
    $new = Set-Or-AddYamlField $new 'source_status' $sourceStatus
    $new = Set-Or-AddYamlField $new 'synthesis_status' $synthStatus

    return $new
}

function Test-EvidencePaths($Row, [string]$Root) {
    $evidence = Get-Field $Row 'synthesis_evidence'
    if ([string]::IsNullOrWhiteSpace($evidence)) { return @() }

    $parts = $evidence -split '[;|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($part in $parts) {
        $clean = $part -replace '^\[\[', '' -replace '\]\]$', ''
        $clean = $clean.Trim()

        # Obsidian aliases: [[path/to/note|alias]]
        if ($clean -match '^(.+?)\|.+$') { $clean = $Matches[1].Trim() }

        # Obsidian headings/blocks: [[path/to/note#heading]] or [[path/to/note^block]]
        $clean = ($clean -split '[#^]')[0].Trim()

        if ([string]::IsNullOrWhiteSpace($clean)) { continue }

        if ($clean -notmatch '\.md$') {
            if ($clean -match '^(wiki|reports|prompts|data)[\\/].+') {
                $clean = "$clean.md"
            } else {
                continue
            }
        }

        $candidate = Resolve-VaultPath -Root $Root -MaybeRelative $clean
        if (-not (Test-Path -LiteralPath $candidate)) {
            $missing.Add($part) | Out-Null
        }
    }

    return @($missing)
}

function Build-FileIndex([string]$Directory, [string]$Filter) {
    $files = @()
    if (Test-Path -LiteralPath $Directory) {
        $files = Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue
    }

    $byName = @{}
    $byVideoIdInName = @{}

    foreach ($file in $files) {
        $byName[$file.FullName.ToLowerInvariant()] = $file.FullName
        if ($file.BaseName -match '([A-Za-z0-9_-]{6,})') {
            foreach ($m in [regex]::Matches($file.Name, '[A-Za-z0-9_-]{6,}')) {
                $id = $m.Value
                if (-not $byVideoIdInName.ContainsKey($id)) { $byVideoIdInName[$id] = $file.FullName }
            }
        }
    }

    return [pscustomobject]@{
        Files = $files
        ByName = $byName
        ByVideoIdInName = $byVideoIdInName
    }
}

function Find-FileByVideoId([string]$VideoId, $Index, [switch]$SearchContents) {
    if ([string]::IsNullOrWhiteSpace($VideoId) -or $null -eq $Index) { return $null }

    if ($Index.ByVideoIdInName.ContainsKey($VideoId)) {
        return $Index.ByVideoIdInName[$VideoId]
    }

    if ($SearchContents) {
        foreach ($file in $Index.Files) {
            if (Select-String -LiteralPath $file.FullName -Pattern $VideoId -SimpleMatch -Quiet -ErrorAction SilentlyContinue) {
                return $file.FullName
            }
        }
    }

    return $null
}

function Read-TextFile([string]$Path) {
    # -Raw -Encoding UTF8 works in Windows PowerShell 5.1 and PowerShell 7+.
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Write-TextFile([string]$Path, [string]$Text) {
    $Text | Set-Content -LiteralPath $Path -Encoding UTF8
}

$VaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
$manifestPath = Join-Path $VaultRoot (Join-Path 'data' 'manifest.csv')
$reportsDir = Join-Path $VaultRoot 'reports'
$sourcesDir = Join-Path $VaultRoot (Join-Path 'wiki' 'sources')
$cleanDir = Join-Path $VaultRoot (Join-Path 'data' 'clean_transcripts')
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }
if (-not (Test-Path -LiteralPath $sourcesDir)) { throw "Sources directory not found: $sourcesDir" }

Ensure-Directory $reportsDir

Write-Info "Building source and clean-transcript indexes..."
$sourceIndex = Build-FileIndex -Directory $sourcesDir -Filter '*.md'
$cleanIndex = Build-FileIndex -Directory $cleanDir -Filter '*.md'

$rows = Import-Csv -LiteralPath $manifestPath
$results = New-Object System.Collections.Generic.List[object]

$total = 0
$sourceMissing = 0
$cleanMissing = 0
$placeholderRows = 0
$stalePendingRows = 0
$evidenceMissingRows = 0
$changedRows = 0
$manifestPathFixRows = 0
$sourceFallbackRows = 0
$cleanFallbackRows = 0

foreach ($row in $rows) {
    $total++
    $videoId = Get-Field $row 'video_id'
    $title = Get-Field $row 'title'
    $sourceRelOriginal = Normalize-RelativePath (Get-Field $row 'source_file')
    $cleanRelOriginal = Normalize-RelativePath (Get-Field $row 'clean_transcript_file')
    $sourceRel = $sourceRelOriginal
    $cleanRel = $cleanRelOriginal
    $synthStatus = Get-Field $row 'synthesis_status'
    $sourceStatus = Get-Field $row 'source_status'

    $sourcePath = Resolve-VaultPath -Root $VaultRoot -MaybeRelative $sourceRel
    if ([string]::IsNullOrWhiteSpace($sourceRel) -or -not (Test-Path -LiteralPath $sourcePath)) {
        $foundSource = Find-FileByVideoId -VideoId $videoId -Index $sourceIndex -SearchContents
        if ($foundSource) {
            $sourcePath = $foundSource
            $sourceRel = Get-RelativePath -Root $VaultRoot -Path $sourcePath
            $sourceFallbackRows++
        }
    }

    $cleanPath = Resolve-VaultPath -Root $VaultRoot -MaybeRelative $cleanRel
    if ([string]::IsNullOrWhiteSpace($cleanRel) -or -not (Test-Path -LiteralPath $cleanPath)) {
        $foundClean = Find-FileByVideoId -VideoId $videoId -Index $cleanIndex
        if ($foundClean) {
            $cleanPath = $foundClean
            $cleanRel = Get-RelativePath -Root $VaultRoot -Path $cleanPath
            $cleanFallbackRows++
        }
    }

    $sourceExists = (-not [string]::IsNullOrWhiteSpace($sourcePath)) -and (Test-Path -LiteralPath $sourcePath)
    $cleanExists = (-not [string]::IsNullOrWhiteSpace($cleanPath)) -and (Test-Path -LiteralPath $cleanPath)

    if (-not $sourceExists) { $sourceMissing++ }
    if (-not $cleanExists) { $cleanMissing++ }

    $placeholderCount = 0
    $stalePending = $false
    $changed = $false
    $manifestPathFix = $false

    if ($sourceExists) {
        $text = Read-TextFile -Path $sourcePath
        $placeholderCount = Count-TemplateArtefacts $text

        if ($placeholderCount -gt 0) { $placeholderRows++ }

        if ($synthStatus -eq 'included' -and ($text -match '(?im)synthesis_status:\s*"?pending"?|Synthesis status:\s*pending')) {
            $stalePending = $true
            $stalePendingRows++
        }

        $fixed = Fix-SourceText -Text $text -Row $row -CleanRel $cleanRel -SourceRel $sourceRel

        if ($fixed -ne $text) {
            $changed = $true
            $changedRows++

            if ($Apply) {
                if ($BackupSourcePages) {
                    $backupPath = "$sourcePath.bak_qa_$timestamp"
                    Copy-Item -LiteralPath $sourcePath -Destination $backupPath -Force
                }

                Write-TextFile -Path $sourcePath -Text $fixed
            }
        }
    }

    if ($UpdateManifestPaths) {
        if ($sourceRel -ne $sourceRelOriginal -and -not [string]::IsNullOrWhiteSpace($sourceRel)) {
            if (Set-FieldIfPresent $row 'source_file' $sourceRel) { $manifestPathFix = $true }
        }
        if ($cleanRel -ne $cleanRelOriginal -and -not [string]::IsNullOrWhiteSpace($cleanRel)) {
            if (Set-FieldIfPresent $row 'clean_transcript_file' $cleanRel) { $manifestPathFix = $true }
        }
        if ($manifestPathFix) { $manifestPathFixRows++ }
    }

    $missingEvidence = Test-EvidencePaths -Row $row -Root $VaultRoot
    if ($missingEvidence.Count -gt 0) { $evidenceMissingRows++ }

    $results.Add([pscustomobject]@{
        video_id = $videoId
        title = $title
        source_file = $sourceRel
        source_exists = $sourceExists
        clean_transcript_file = $cleanRel
        clean_exists = $cleanExists
        source_status = $sourceStatus
        synthesis_status = $synthStatus
        placeholder_count = $placeholderCount
        stale_pending_text = $stalePending
        missing_synthesis_evidence = ($missingEvidence -join ' | ')
        would_change_source = $changed
        source_found_by_fallback = ($sourceRel -ne $sourceRelOriginal -and -not [string]::IsNullOrWhiteSpace($sourceRel))
        clean_found_by_fallback = ($cleanRel -ne $cleanRelOriginal -and -not [string]::IsNullOrWhiteSpace($cleanRel))
        would_update_manifest_paths = $manifestPathFix
    }) | Out-Null
}

if ($Apply -and $UpdateManifestPaths -and $manifestPathFixRows -gt 0) {
    $manifestBackupPath = "$manifestPath.bak_qa_$timestamp"
    Copy-Item -LiteralPath $manifestPath -Destination $manifestBackupPath -Force
    $rows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
}

$csvPath = Join-Path $reportsDir "qa_source_reconciliation_$timestamp.csv"
$mdPath = Join-Path $reportsDir "qa_source_reconciliation_$timestamp.md"

$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$topIssues = $results |
    Where-Object {
        $_.placeholder_count -gt 0 -or
        $_.stale_pending_text -eq $true -or
        $_.source_exists -eq $false -or
        $_.clean_exists -eq $false -or
        $_.missing_synthesis_evidence -ne '' -or
        $_.source_found_by_fallback -eq $true -or
        $_.clean_found_by_fallback -eq $true
    } |
    Select-Object -First 60

$mode = if ($Apply) { 'APPLY' } else { 'REPORT ONLY' }
$manifestMode = if ($UpdateManifestPaths) { 'enabled' } else { 'disabled' }

$md = @"
# QA Source Reconciliation Report

Run timestamp: $timestamp
Mode: $mode
Vault: ``$VaultRoot``
Manifest path updates: $manifestMode

## Summary

| Check | Count |
|---|---:|
| Manifest rows checked | $total |
| Missing source pages | $sourceMissing |
| Missing clean transcript files | $cleanMissing |
| Rows with template artefacts | $placeholderRows |
| Rows with stale pending synthesis text | $stalePendingRows |
| Rows with missing synthesis evidence paths | $evidenceMissingRows |
| Source pages that would change / changed | $changedRows |
| Source pages found by fallback | $sourceFallbackRows |
| Clean transcripts found by fallback | $cleanFallbackRows |
| Manifest path rows that would update / updated | $manifestPathFixRows |

## Interpretation

This report checks whether source pages are reliable source-of-information pages for the wiki.

The highest-priority issues are:

1. Literal template artefacts such as video ID placeholders or Get-RelativePath placeholder text.
2. Source pages saying synthesis is pending while the manifest says synthesis is included.
3. Broken source or clean transcript references.
4. Broken synthesis evidence references.
5. Manifest paths that can be resolved by fallback and may need reconciliation.

## Output files

CSV detail report:

``$csvPath``

## Top issue rows

| video_id | source_exists | clean_exists | synthesis_status | placeholder_count | stale_pending_text | source_fallback | clean_fallback | would_change_source |
|---|---:|---:|---|---:|---:|---:|---:|---:|
"@

foreach ($issue in $topIssues) {
    $md += "`n| $(Convert-ToMarkdownSafe $issue.video_id) | $($issue.source_exists) | $($issue.clean_exists) | $(Convert-ToMarkdownSafe $issue.synthesis_status) | $($issue.placeholder_count) | $($issue.stale_pending_text) | $($issue.source_found_by_fallback) | $($issue.clean_found_by_fallback) | $($issue.would_change_source) |"
}

$md += @"

## Recommended next action

If this was a report-only run and the results look sensible, apply deterministic fixes:

````powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\qa_reconcile_sources.ps1" -Apply -BackupSourcePages
````

If fallback path resolution found files and you want the manifest paths reconciled too, run:

````powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\qa_reconcile_sources.ps1" -Apply -BackupSourcePages -UpdateManifestPaths
````

After applying fixes, rerun report-only mode and confirm that:

- placeholder rows are zero or materially reduced;
- stale pending synthesis text is zero;
- source and clean transcript references exist;
- synthesis evidence paths are valid or explained;
- fallback path rows are zero if manifest path reconciliation was applied.

"@

Write-TextFile -Path $mdPath -Text $md

Write-Ok 'QA reconciliation complete'
Write-Host "Mode: $mode"
Write-Host "Rows checked: $total"
Write-Host "Missing source pages: $sourceMissing"
Write-Host "Missing clean transcripts: $cleanMissing"
Write-Host "Rows with template artefacts: $placeholderRows"
Write-Host "Rows with stale pending synthesis text: $stalePendingRows"
Write-Host "Rows with missing synthesis evidence paths: $evidenceMissingRows"
Write-Host "Source pages that would change / changed: $changedRows"
Write-Host "Source pages found by fallback: $sourceFallbackRows"
Write-Host "Clean transcripts found by fallback: $cleanFallbackRows"
Write-Host "Manifest path rows that would update / updated: $manifestPathFixRows"
Write-Host ''
Write-Host "Report: $mdPath"
Write-Host "CSV:    $csvPath"

if (-not $Apply) {
    Write-Warn 'Report-only mode. No source pages were modified.'
    Write-Warn 'Run with -Apply to write deterministic fixes.'
} else {
    Write-Ok 'Apply mode complete. Source pages were updated where deterministic fixes were available.'
    if ($UpdateManifestPaths -and $manifestPathFixRows -gt 0) {
        Write-Ok 'Manifest path reconciliation was also applied. A manifest backup was created.'
    }
}
