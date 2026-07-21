# Agentic Knowledge Vault Pipeline — prototype

This is a small, runnable PowerShell prototype for maintaining an Obsidian-style knowledge vault from an authorised YouTube channel. It is based on a production prototype, but has been generalised: no transcripts, cookies, accounts, server details, or personal data are included.

## What it does

1. Reads a channel URL from `config/vault.example.json`.
2. Uses `yt-dlp` to discover video metadata.
3. Records unseen videos in `data/manifest.csv`.
4. Optionally downloads only the chosen caption track.
5. Creates traceable source-note placeholders and a synthesis prompt.
6. Writes a run report. It never calls an LLM itself.

## Quick start

Requires PowerShell 7+ and `yt-dlp` on `PATH`.

```powershell
Copy-Item config/vault.example.json config/vault.json
pwsh ./scripts/Initialize-Vault.ps1 -VaultRoot ./demo-vault
pwsh ./scripts/Update-Vault.ps1 -VaultRoot ./demo-vault -ConfigPath ./config/vault.json -ReportOnly
```

Use `-Apply` only after checking the report. A supplied cookie file is optional and stays outside the repository.

## Scope

This public prototype deliberately excludes unattended LLM execution, notification services, cloud scheduling, cookies, and sync credentials. Those belong to a deployer-owned private configuration.
