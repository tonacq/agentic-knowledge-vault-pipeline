[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$VaultRoot,
 [Parameter(Mandatory)][string]$ConfigPath,
 [switch]$ReportOnly,
 [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if ($Apply -eq $ReportOnly) { throw 'Specify exactly one of -ReportOnly or -Apply.' }
$config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
if (-not (Get-Command $config.ytDlpPath -ErrorAction SilentlyContinue)) { throw "yt-dlp not found: $($config.ytDlpPath)" }
& (Join-Path $PSScriptRoot 'Initialize-Vault.ps1') -VaultRoot $VaultRoot
$manifestPath = Join-Path $VaultRoot 'data/manifest.csv'
$rows = @(Import-Csv $manifestPath); $byId=@{}; foreach($r in $rows){$byId[$r.video_id]=$r}
$json = & $config.ytDlpPath --flat-playlist --dump-single-json --playlist-end $config.maxVideos $config.channelUrl
if ($LASTEXITCODE -ne 0) { throw 'yt-dlp discovery failed.' }
$entries = @((($json | ConvertFrom-Json).entries))
$today=Get-Date -Format 'yyyy-MM-dd'; $new=@()
foreach($e in $entries){
 $id=[string]$e.id; if([string]::IsNullOrWhiteSpace($id)){continue}
 if(-not $byId.ContainsKey($id)){
  $new += [pscustomobject]@{video_id=$id;title=[string]$e.title;url="https://www.youtube.com/watch?v=$id";upload_date=[string]$e.upload_date;transcript_file='';transcript_status='pending';source_file="wiki/sources/$id.md";source_status='pending';synthesis_status='pending';synthesis_evidence='';last_checked=$today}
 } else {$byId[$id].last_checked=$today}
}
if($Apply -and $new.Count){
 foreach($r in $new){
  $page=Join-Path $VaultRoot $r.source_file; @("---","type: source","video_id: $($r.video_id)","title: `"$($r.title -replace '"','\"')`"","url: $($r.url)","synthesis_status: pending","---",'',"# $($r.title)",'','## Source status','','Transcript retrieval and synthesis are pending.') | Set-Content -Encoding utf8 $page
 }
 $rows += $new; $rows | Export-Csv -NoTypeInformation -Encoding utf8 $manifestPath
}
$report=Join-Path $VaultRoot 'reports/latest_weekly_update.md'
@('# Latest Vault Update','',"- Mode: $(if($Apply){'APPLY'}else{'REPORT ONLY'})","- Videos scanned: $($entries.Count)","- New videos found: $($new.Count)","- Synthesis required: $(if($new.Count){'YES'}else{'NO'})","- Date: $today") | Set-Content -Encoding utf8 $report
Write-Host "Scanned $($entries.Count); new: $($new.Count). Report: $report" -ForegroundColor Green
