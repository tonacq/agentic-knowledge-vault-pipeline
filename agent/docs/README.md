# WikiAgent — Agent Documentation

`agent/` is the shared engine. It contains no vault-specific data — see `01-architecture-spec.md`
(copied into this folder as `architecture-spec.md`) for the locked rules this build follows.

## Scripts (`agent/scripts/`)

| Script | Responsibility |
|---|---|
| `run-vault.ps1` | Entry point. Orchestrates one vault through the full pipeline; owns locking. |
| `ingest-youtube.ps1` | Channel scan + canonical-caption download into the vault's manifest. |
| `ingest-documents.ps1` | Registers manually dropped PDFs/DOCX/MD/TXT from `input/`. |
| `create-source-pages.ps1` | Deterministic, zero-Claude-token source page generation. |
| `run-claude-synthesis.ps1` | Headless Claude Code invocation; writes an intermediate result, never the manifest directly. |
| `run-qa.ps1` | The one authoritative, idempotent manifest reconciliation pass. |
| `backup-vault.ps1` | Vault-scoped backup + optional remote sync + retention. |
| `send-notification.ps1` | Best-effort Telegram summary; never fails the run. |

## Scheduling (`agent/scheduling/`)

See `schedule-contract.md`. Short version: edit `schedule.csv`, nothing else, to add a vault
to the rotation.

## Known gaps to close before production cutover

This build is a from-spec skeleton with working control-flow, locking, and manifest logic.
Before it replaces the validated single-vault VM implementation, port in from the proven VM
scripts (referenced throughout the project's continuation-brief history, not verbatim
available to this build):
- exact yt-dlp flags/impersonation workarounds already proven on the VM;
- the real DOCX/PDF text extractors (currently placeholder markers in `ingest-documents.ps1`);
- Claude Code subscription-auth wiring specific to the target host;
- the exact `claude_budget_usd` enforcement behaviour (currently a soft, unenforced field,
  matching the locked Summary 9 decision to keep it soft for now).

## YouTube access via VPN/proxy — host prerequisite, not something this package sets up

The production VM cannot reach YouTube directly (cloud/datacenter IPs get blocked). The
proven fix, documented in the project's earlier continuation briefs, is a Proton WireGuard
tunnel exposed locally as a SOCKS5 proxy via `wireproxy`, running as its own systemd service
(`wireproxy-youtube.service`) independent of WikiAgent, listening on
`socks5h://127.0.0.1:25344`.

WikiAgent's role is only to *use* that proxy: `vault.json`'s `proxy` field is passed straight
through to `yt-dlp --proxy` in `ingest-youtube.ps1`. This build does **not** install or manage
wireproxy/WireGuard itself — that has to exist on the host before `ingest-youtube.ps1` will
work against a real YouTube channel. Set `vault.json → proxy` to
`socks5h://127.0.0.1:25344` once that service is running, or leave it blank if the host
doesn't need one.

## Telegram notifications

Matched to the proven three-message pattern from `run_nate_herk_weekly.sh`: a run that
couldn't start (lock contention), a run that failed mid-pipeline (with exit code and log
path), and a successful run — sent from `run-vault.ps1` at the exact points those events
happen, not as one generic end-of-run message.

Credentials (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) are read from, in order: already-set
process environment variables, then `<vault>/config/secrets.env`, then a shared
`agent/secrets.env`. Copy `config/secrets.env.example` in `vaults/_template/` to
`secrets.env` and fill it in per vault (or once at the agent level if every vault shares one
bot/chat). No file means notifications are silently skipped, not an error.
