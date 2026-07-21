# Wiki Agent Factory

An installable PowerShell pipeline that turns a permitted YouTube channel into an Obsidian knowledge vault.

It is a generalised version of a live Oracle Ubuntu workflow. It does real work:

1. scans a configured channel with `yt-dlp`;
2. records only unseen videos in `data/manifest.csv`;
3. downloads permitted auto-captions, cleans VTT into plain text, and writes source notes;
4. produces a bounded Claude Code synthesis hand-off;
5. runs deterministic reconciliation QA;
6. optionally backs up/synchronises the vault with rclone and sends a Telegram completion message.

No account credentials, cookies, Telegram tokens, VM paths, transcripts, or creator-specific data are included.

## What to install

This package is for Ubuntu 24.04 on an Oracle VM (or another Linux host) and uses PowerShell 7.

Required: `pwsh`, `yt-dlp`, `rclone`, `git`, `curl`.

For AI synthesis: an authenticated `claude` CLI. The pipeline can still ingest, clean and QA a vault with `-SkipClaude`.

For scheduled runs: `systemd` (already present on Ubuntu).

## Quick start

```bash
git clone https://github.com/tonacq/agentic-knowledge-vault-pipeline.git
cd agentic-knowledge-vault-pipeline
pwsh -File ./install-wiki-agent.ps1 -VaultRoot ~/wiki-agent/working/my-channel
cp ./config/vault.example.json ~/wiki-agent/working/my-channel/config/vault.json
# edit channel_url, creator, and optional Drive / proxy settings
pwsh -File ./scripts/Run-WeeklyPipeline.ps1 -VaultRoot ~/wiki-agent/working/my-channel -SkipClaude
```

See [docs/INSTALL.md](docs/INSTALL.md) for exact Ubuntu commands, Google Drive configuration, Telegram setup and systemd scheduling.

## Safety boundary

Use only with sources you are authorised to ingest. Cookie files, bot tokens and rclone configuration stay on the host and are excluded by `.gitignore`. This repository deliberately contains no copied creator transcripts or private vault material.
