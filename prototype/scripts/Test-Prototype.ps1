$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../.test-vault'
& (Join-Path $PSScriptRoot 'Initialize-Vault.ps1') -VaultRoot $root
if(-not (Test-Path (Join-Path $root 'data/manifest.csv'))){throw 'Manifest was not created.'}
Write-Host 'PASS: vault initialisation' -ForegroundColor Green
