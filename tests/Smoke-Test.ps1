[CmdletBinding()]
param([string]$Workspace = (Join-Path ([IO.Path]::GetTempPath()) 'wiki-agent-factory-smoke'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (Test-Path $Workspace) { Remove-Item -Recurse -Force $Workspace }
New-Item -ItemType Directory -Force $Workspace | Out-Null

& pwsh -NoProfile -File (Join-Path $root 'install-wiki-agent.ps1') -VaultRoot $Workspace -SkipDependencyCheck
if ($LASTEXITCODE) { throw 'Installer failed.' }
$config = Get-Content -Raw (Join-Path $Workspace 'config/vault.example.json') | ConvertFrom-Json
$config.channel_url = 'https://example.invalid/channel'
$config.creator = 'Fixture creator'
$config.yt_dlp_path = (Join-Path $root 'tests/fake-ytdlp.ps1')
$config | ConvertTo-Json | Set-Content (Join-Path $Workspace 'config/vault.json') -Encoding utf8

& pwsh -NoProfile -File (Join-Path $Workspace 'scripts/Run-WeeklyPipeline.ps1') -VaultRoot $Workspace -SkipClaude
# Exit code 2 = "ACTION REQUIRED - SYNTHESIS SKIPPED", the documented, intentional
# outcome of run_weekly_agentic_pipeline_v2.ps1 when -SkipClaude is passed and
# synthesis is pending -- which is exactly what this smoke test deliberately
# triggers (single fixture video, -SkipClaude above). It is not a failure; this
# test does not exercise Claude and only asserts on ingest artefacts below. Any
# other non-zero code is a real failure.
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "Pipeline failed with exit code $LASTEXITCODE." }
$row = @(Import-Csv (Join-Path $Workspace 'data/manifest.csv')) | Select-Object -First 1
if (!$row -or $row.video_id -ne 'abc123DEF45') { throw 'Expected manifest row was not created.' }
if (!(Test-Path (Join-Path $Workspace $row.clean_transcript_file))) { throw 'Clean transcript was not created.' }
if (!(Test-Path (Join-Path $Workspace $row.source_file))) { throw 'Source note was not created.' }
if (!(Test-Path (Join-Path $Workspace 'prompts'))) { throw 'Synthesis prompt directory was not created.' }
Write-Host 'Smoke test passed.' -ForegroundColor Green
