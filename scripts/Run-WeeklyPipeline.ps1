[CmdletBinding()]
param([Parameter(Mandatory)][string]$VaultRoot,[switch]$SkipClaude)
$ErrorActionPreference='Stop';$VaultRoot=[IO.Path]::GetFullPath($VaultRoot);$here=Split-Path -Parent $PSCommandPath
& pwsh -NoProfile -File (Join-Path $here 'Update-YoutubeVault.ps1') -VaultRoot $VaultRoot -Apply;if($LASTEXITCODE){throw 'Ingest stage failed.'}
$pending=@(Import-Csv (Join-Path $VaultRoot 'data/manifest.csv')|Where-Object{$_.synthesis_status -eq 'pending'})
if($pending.Count -and !$SkipClaude){$config=Get-Content -Raw (Join-Path $VaultRoot 'config/vault.json')|ConvertFrom-Json;if(!(Get-Command claude -ErrorAction SilentlyContinue)){throw 'Claude CLI is not installed/authenticated. Re-run with -SkipClaude or see docs/INSTALL.md.'};$prompt=Get-ChildItem (Join-Path $VaultRoot 'prompts') -Filter 'weekly_synthesis_*.md'|Sort-Object LastWriteTime|Select-Object -Last 1;$result=Get-Content -Raw $prompt.FullName|& claude -p --effort $config.claude_effort --max-budget-usd $config.claude_budget_usd 2>&1;$result|Set-Content (Join-Path $VaultRoot 'reports/claude_last_run.log') -Encoding utf8;if($LASTEXITCODE){throw 'Claude synthesis stage failed.'}}
& pwsh -NoProfile -File (Join-Path $here 'Test-Reconcile.ps1') -VaultRoot $VaultRoot;if($LASTEXITCODE){throw 'QA stage failed.'}
Write-Host 'Weekly pipeline complete.' -ForegroundColor Green
