# WikiAgent — Agent Documentation

`agent/` is the shared engine. It contains no vault-specific data — see `01-architecture-spec.md`
(copied into this folder as `architecture-spec.md`) for the locked rules this build follows.

## Scripts (`agent/scripts/`)

| Script | Responsibility |
|---|---|
| `run-vault.ps1` | Entry point. Orchestrates one vault through the full pipeline; owns locking. |
| `ingest-youtube.ps1` | Channel scan + canonical-caption download into the vault's manifest. |
| `clean-transcripts.ps1` | Converts raw `.vtt` captions to clean plain text; sets `clean_status` so `create-source-pages.ps1` can act on youtube-sourced rows. |
| `ingest-documents.ps1` | Registers manually dropped PDFs/DOCX/MD/TXT from `input/`. |
| `create-source-pages.ps1` | Deterministic, zero-Claude-token source page generation. |
| `run-claude-synthesis.ps1` | Headless Claude Code invocation; writes an intermediate result, never the manifest directly. |
| `run-qa.ps1` | The one authoritative, idempotent manifest reconciliation pass. |
| `backup-vault.ps1` | Vault-scoped backup + optional remote sync + retention. |
| `restore-vault.ps1` | Restores config/manifest/wiki from a `backup-vault.ps1` archive and rebuilds the scaffold; refuses to overwrite a non-empty vault without `-Force`. |
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

## Resolved gaps

- **Clean-transcript stage (fixed).** This gap was real but was *not* on the list above when
  it was found — worth the paper trail. The multivault rewrite carried over `ingest-youtube.ps1`
  without porting the VTT-to-clean-text conversion step that the proven VM pipeline
  (`weekly_update_channel_wiki_v8_linux.ps1`'s `Convert-VttToPlainText`) already had working.
  Youtube-sourced manifest rows stayed at `clean_status = ''` forever, so
  `create-source-pages.ps1` (which gates on `clean_status = clean_ready`) could never fire for
  them, regardless of caption-download success. `ingest-documents.ps1` was unaffected — it
  already sets `clean_status = 'clean_ready'` directly since dropped documents need no cleaning.
  Fixed by porting `Convert-VttToPlainText` and the `clean_ready` /
  `blocked_missing_transcript` transition logic into a new standalone `clean-transcripts.ps1`
  stage, wired into `run-vault.ps1` between `ingest-youtube.ps1` and `ingest-documents.ps1`
  (skippable via `-SkipClean`, matching the existing `-Skip*` convention).

- **Pull-clobber data loss (fixed).** `sync-vault.ps1`'s pull stage ran `rclone sync` from
  Drive to the local vault directory unconditionally — since vault directories are not
  git-tracked (Drive is their only "last known good" record), any local file that hadn't
  been pushed yet was silently deleted or overwritten, no warning. This destroyed real local
  state three times during multivault testing: two config edits and one full set of
  manifest/wiki artifacts from clean-transcript retesting. Fixed by running
  `rclone check $VaultRoot $remote --one-way --combined -` before every pull and aborting
  with the specific at-risk file list if it finds anything local that Drive doesn't already
  have, instead of proceeding. Add `-ForcePull` to skip the check and pull anyway when an
  overwrite is intentional. Verified: a deliberate local-only file blocks the pull with a
  clear error and survives the run; a normal run with nothing local pending pulls and
  proceeds exactly as before.

- **`run-qa.ps1` archive-then-commit ordering (fixed).** The synthesis-result.json file was
  archived (`Move-Item` to `.processed`) *before* the manifest write was committed. A crash
  in that gap silently and unrecoverably lost the evidence that synthesis had completed for
  those rows - the archived result file was gone, so nothing could ever reconstruct which
  pages were created; the affected rows stayed `synthesis_status = pending` and would be
  re-synthesized by Claude on the next run at real, duplicate paid API cost. Found via code
  reading, then confirmed with a controlled reproduction (archive the result file manually,
  skip the manifest write, run `run-qa.ps1` again - the rows never recovered). Fixed by
  reversing the order: commit the manifest write first, archive the result file second. A
  crash in the new gap (after commit, before archive) leaves the manifest already correct;
  worst case a result file is left un-archived, which the next run picks up and archives
  cleanly (`synthesis_status = included` already set, so Finding D just skips it - no
  double-processing). Verified against the fixed script with a real failure injected at the
  archive step (target directory made read-only): the manifest committed correctly despite
  the archive genuinely failing, and a subsequent normal run cleanly archived the leftover
  file with zero manifest changes. Selective transition, evidence recording, idempotency,
  and Finding D all re-confirmed with no regression.

- **No restore mechanism (fixed).** `backup-vault.ps1` produced correct, complete archives,
  but nothing could restore one - no `restore-vault.ps1`, no documented manual procedure.
  Investigation found two specific problems any restore would have to handle: (1)
  `Compress-Archive` was given `working/manifest.csv` as a bare file path, so it landed at
  the zip root instead of `working/manifest.csv` - a naive `Expand-Archive` would leave the
  manifest invisible to every pipeline script; (2) `Compress-Archive` silently drops
  zero-byte files, so the empty scaffold folders (`wiki/concepts/`, `wiki/synthesis/`, etc.)
  never made it into the archive (low severity - every script recreates them via
  `New-Item -Force` on its next run, but a fresh restore shouldn't need a pipeline run first
  just to become valid). Fixed at the source: `backup-vault.ps1` now stages `config/`, `wiki/`,
  and `working/manifest.csv` into a temp directory that mirrors the desired archive layout
  before compressing, so the manifest lands at the correct relative path from now on. Added
  `agent/scripts/restore-vault.ps1`: restores config/manifest/wiki from a backup archive
  (handling both the old flattened-manifest layout and the new correct one), then explicitly
  recreates the full `_template`-matching scaffold (12 directories, each with `.gitkeep`) so
  a restored vault is immediately usable. Refuses to restore into a non-empty vault directory
  without `-Force`. Verified: fresh backup's zip structure confirmed correct via `unzip -l`;
  restored into a sandbox copy of DWSIM after deliberately deleting a wiki page and corrupting
  the manifest - both recovered byte-identical to the pre-corruption state, full scaffold
  present with no pipeline run needed; safety check confirmed to refuse overwriting the live
  DWSIM vault without `-Force`; live DWSIM and Nate_Herk both confirmed untouched throughout.

- **Systemd unit path defect (fixed, source-only - not deployed today).**
  `wikiagent.service`'s `WorkingDirectory`/`ExecStart` referenced `/home/ubuntu/WikiAgent`, a
  path that has never existed on the VM - confirmed absent, and matching neither the current
  production path (`/home/ubuntu/wiki-agent`) nor any real multivault deployment. Also
  confirmed via `systemctl`/`/etc/systemd` search that these units have never actually been
  installed; only the old `nate-herk-weekly.service`/`.timer` are live. Per the project's
  existing Key Decisions (parallel deployment precedes cutover - the old Nate timer stays
  enabled until a controlled cutover), the fix corrects the unit to reference
  `/home/ubuntu/wiki-agent-multivault`: the intended eventual parallel-deployment path,
  distinct from both the current production path and the placeholder. No directory was
  created or renamed - source-file correction only; the real deployment happens at actual
  cutover planning. Verified with `systemd-analyze verify` directly against the uninstalled
  file (no install/enable required): `wikiagent.timer` verifies clean; `wikiagent.service`
  reports only that its target script doesn't exist yet at the not-yet-deployed path -
  confirmed via a control check against the real, installed `nate-herk-weekly.service` that
  this is expected baseline behavior, not a defect. Separately confirmed the hourly/UTC timer
  design (vs. the old weekly/timezone-aware one) is deliberate, not a gap: `schedule-contract.md`
  documents `time_utc` as "matched to the hour by the hourly systemd timer" - `schedule.csv`
  is where per-vault timing actually lives (arbitrary `day_of_week`/`time_utc` per row,
  UTC-normalized), and the timer's only job is to fire often enough to catch it. Dry-ran
  `run-wikiagent.sh`'s exact matching/resolution logic against schedule.csv's real rows
  (targeting `/home/ubuntu/test-multivault`, where vaults currently live) via a temporary,
  non-invoking harness: both `DWSIM` and `Nate_Herk` correctly resolved to their real vault
  paths and job types; `_template` correctly skipped; both correctly reported as not firing
  today (`enabled=false`) - nothing was installed, enabled, started, or actually dispatched.

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
