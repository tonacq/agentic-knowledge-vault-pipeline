[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultRoot,
    [switch]$Apply,
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'
if ($Apply -and $ReportOnly) { throw 'Use either -Apply or -ReportOnly.' }
if (-not $Apply) { $ReportOnly = $true }

function Get-Rel([string]$Root, [string]$Path) {
    $rootUri = [uri](([IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('/','\\'))) + [IO.Path]::DirectorySeparatorChar)
    $pathUri = [uri][IO.Path]::GetFullPath($Path)
    return [uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('\\','/')
}
function Slug([string]$Text) {
    $value = (($Text.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+','-').Trim('-'))
    if (!$value) { return 'untitled' }
    return $value.Substring(0, [Math]::Min(90, $value.Length))
}
function VttToText([string]$Input, [string]$Output) {
    $result = [Collections.Generic.List[string]]::new(); $previous = ''
    foreach ($line in Get-Content -LiteralPath $Input -Encoding utf8) {
        $text = $line.Trim()
        if (!$text -or $text -eq 'WEBVTT' -or $text -match '-->' -or $text -match '^\d+$' -or $text -match '^(Kind|Language):') { continue }
        $text = [regex]::Replace($text, '<[^>]+>', '') -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
        $text = [regex]::Replace($text, '\s+', ' ').Trim()
        if ($text -and $text -ne $previous) { $result.Add($text); $previous = $text }
    }
    $result -join ' ' | Set-Content -LiteralPath $Output -Encoding utf8
}
function Write-Report([string]$Path, [string]$Mode, [int]$Found, [int]$New, [int]$Downloaded, [int]$Failed, [string]$Prompt) {
@"
# Weekly vault update

- Run status: **COMPLETE**
- Mode: $Mode
- Videos scanned: $Found
- New videos found: $New
- Transcripts downloaded: $Downloaded
- Missing/failed transcripts: $Failed
- Synthesis required: **$(if ($New -gt 0 -and $Downloaded -gt 0) {'YES'} else {'NO'})**
- Prompt generated: $(if ($Prompt) {$Prompt} else {'none'})
"@ | Set-Content -LiteralPath $Path -Encoding utf8
}

$VaultRoot = [IO.Path]::GetFullPath($VaultRoot)
$configPath = Join-Path $VaultRoot 'config/vault.json'
if (!(Test-Path -LiteralPath $configPath)) { throw "Missing $configPath. Copy config/vault.example.json and configure it." }
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$manifestPath = Join-Path $VaultRoot 'data/manifest.csv'
if (!(Test-Path $manifestPath)) { throw "Missing manifest: $manifestPath. Run install-wiki-agent.ps1 first." }
$rows = @(Import-Csv -LiteralPath $manifestPath)
$known = @{}; foreach ($row in $rows) { $known[$row.video_id] = $true }

$scanArgs = @('--flat-playlist','--dump-single-json','--no-warnings','--playlist-end',[string]$config.max_videos,$config.channel_url)
if ($config.proxy) { $scanArgs = @('--proxy',$config.proxy) + $scanArgs }
$scan = & $config.yt_dlp_path @scanArgs 2>&1
if ($LASTEXITCODE -ne 0) { throw "yt-dlp scan failed: $($scan -join [Environment]::NewLine)" }
$playlist = ($scan -join [Environment]::NewLine) | ConvertFrom-Json
$entries = @($playlist.entries | Where-Object { $_.id })
$newEntries = @($entries | Where-Object { -not $known.ContainsKey([string]$_.id) })
if ($ReportOnly) { Write-Host "Scanned $($entries.Count); new $($newEntries.Count)." -ForegroundColor Cyan; return }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'; $downloaded = 0; $failed = 0; $promptLines = [Collections.Generic.List[string]]::new()
foreach ($entry in $newEntries) {
    $id = [string]$entry.id; $title = [string]$entry.title; if (!$title) {$title=$id}
    $url = "https://www.youtube.com/watch?v=$id"; $rawDir = Join-Path $VaultRoot 'raw'; $cleanDir=Join-Path $VaultRoot 'data/clean_transcripts'; $sourceDir=Join-Path $VaultRoot 'wiki/sources'
    $downloadArgs = @('--skip-download','--write-auto-subs','--sub-langs',($config.caption_languages -join ','),'--sub-format','vtt','--output',(Join-Path $rawDir '%(id)s.%(ext)s'),$url)
    if ($config.proxy) {$downloadArgs=@('--proxy',$config.proxy)+$downloadArgs}; if ($config.cookie_file) {$downloadArgs=@('--cookies',$config.cookie_file)+$downloadArgs}; if ($config.js_runtime) {$downloadArgs=@('--js-runtimes',$config.js_runtime)+$downloadArgs}
    $out = & $config.yt_dlp_path @downloadArgs 2>&1
    $vtt = Get-ChildItem -LiteralPath $rawDir -Filter "$id*.vtt" -File | Sort-Object @{Expression={if ($_.Name -match 'en-orig') {0} else {1}}}, Name | Select-Object -First 1
    if (!$vtt) {
        $failed++; $rows += [pscustomobject]@{video_id=$id;title=$title;url=$url;upload_date=[string]$entry.upload_date;transcript_status='missing';clean_status='';source_status='';synthesis_status='';synthesis_batch='';synthesis_last_checked='';raw_vtt_file='';clean_transcript_file='';source_file='';synthesis_evidence='';last_error=($out -join ' ')}; continue
    }
    $cleanPath = Join-Path $cleanDir "$id--$(Slug $title).txt"; VttToText $vtt.FullName $cleanPath
    $sourcePath = Join-Path $sourceDir "$id--$(Slug $title).md"; $cleanRel=Get-Rel $VaultRoot $cleanPath; $rawRel=Get-Rel $VaultRoot $vtt.FullName; $sourceRel=Get-Rel $VaultRoot $sourcePath
@"
---
type: source
video_id: "$id"
title: "$($title.Replace('"','\"'))"
url: "$url"
creator: "$($config.creator.Replace('"','\"'))"
upload_date: "$($entry.upload_date)"
clean_transcript_file: "$cleanRel"
source_status: "source_created"
synthesis_status: "pending"
---

# $title

- Creator: $($config.creator)
- Video: $url
- Clean transcript: $cleanRel

## Status

Awaiting synthesis.
"@ | Set-Content -LiteralPath $sourcePath -Encoding utf8
    $rows += [pscustomobject]@{video_id=$id;title=$title;url=$url;upload_date=[string]$entry.upload_date;transcript_status='downloaded';clean_status='clean_ready';source_status='source_created';synthesis_status='pending';synthesis_batch='';synthesis_last_checked='';raw_vtt_file=$rawRel;clean_transcript_file=$cleanRel;source_file=$sourceRel;synthesis_evidence='';last_error=''}
    $promptLines.Add("- $title — source: $sourceRel; transcript: $cleanRel"); $downloaded++
}
$rows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding utf8
$promptPath = ''
if ($promptLines.Count -gt 0) { $promptPath=Join-Path $VaultRoot "prompts/weekly_synthesis_$stamp.md"; @("# Weekly synthesis","","Read CLAUDE.md, then synthesise only these new source records:","",$promptLines,"","Update the manifest evidence/status fields for every completed source.") | Set-Content -LiteralPath $promptPath -Encoding utf8 }
$promptRelative = ''
if ($promptPath) { $promptRelative = Get-Rel $VaultRoot $promptPath }
$reports=Join-Path $VaultRoot 'reports'; New-Item -ItemType Directory -Path $reports -Force|Out-Null; $report=Join-Path $reports "weekly_update_$stamp.md"; Write-Report $report 'APPLY' $entries.Count $newEntries.Count $downloaded $failed $promptRelative; Copy-Item $report (Join-Path $reports 'latest_weekly_update.md') -Force
Write-Host "Complete: scanned $($entries.Count), ingested $downloaded, failed $failed." -ForegroundColor Green
