[CmdletBinding()]
param([Parameter(Mandatory)][string]$VaultRoot)
$ErrorActionPreference='Stop'; $VaultRoot=[IO.Path]::GetFullPath($VaultRoot); $rows=@(Import-Csv (Join-Path $VaultRoot 'data/manifest.csv')); $missingClean=0;$missingSource=0;$badIncluded=0
foreach($row in $rows){ if($row.clean_transcript_file -and !(Test-Path (Join-Path $VaultRoot $row.clean_transcript_file))){$missingClean++}; if($row.source_file -and !(Test-Path (Join-Path $VaultRoot $row.source_file))){$missingSource++}; if($row.synthesis_status -eq 'included' -and !$row.synthesis_evidence){$badIncluded++} }
$text=@("# Vault reconciliation","","- Rows checked: $($rows.Count)","- Missing clean transcripts: $missingClean","- Missing source pages: $missingSource","- Included rows missing evidence: $badIncluded"); $reports=Join-Path $VaultRoot 'reports';New-Item -ItemType Directory -Force $reports|Out-Null;$text|Set-Content (Join-Path $reports 'latest_reconciliation.md') -Encoding utf8
if($missingClean -or $missingSource -or $badIncluded){throw 'Reconciliation failed. See reports/latest_reconciliation.md.'};Write-Host 'Reconciliation passed.' -ForegroundColor Green
