[CmdletBinding()]
param([Parameter(Mandatory)][string]$VaultRoot,[switch]$SkipClaude)

$ErrorActionPreference = 'Stop'
$canonical = Join-Path $PSScriptRoot 'run_weekly_agentic_pipeline_v2.ps1'
if (-not (Test-Path -LiteralPath $canonical)) {
    throw "Canonical pipeline is missing: $canonical. Re-run install-wiki-agent.ps1 from the Factory branch."
}
& pwsh -NoProfile -ExecutionPolicy Bypass -File $canonical -VaultRoot $VaultRoot -SkipClaude:$SkipClaude
exit $LASTEXITCODE
