[CmdletBinding()]
param([Parameter(Mandatory)][string]$VaultRoot,[switch]$Apply)

$ErrorActionPreference = 'Stop'
$canonical = Join-Path $PSScriptRoot 'qa_reconcile_sources_v3.ps1'
if (-not (Test-Path -LiteralPath $canonical)) {
    throw "Canonical QA script is missing: $canonical. Re-run install-wiki-agent.ps1 from the Factory branch."
}
& pwsh -NoProfile -ExecutionPolicy Bypass -File $canonical -VaultRoot $VaultRoot -Apply:$Apply
exit $LASTEXITCODE
