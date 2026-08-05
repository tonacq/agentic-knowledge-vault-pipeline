# WikiAgent — Claude build

Built by Claude directly against the **locked WikiAgent Architecture Specification v1.0**
and its governance pack (`01-architecture-spec.md` through `05-decision-log.md`,
`03-architecture-conformance-test.ps1`) found in this project's Google Drive
`02-Current-Files/Artefacts/` folder — the same spec the ChatGPT-produced
`wiki-agent-multivault-rev10-vm-deployable` package was supposed to conform to but was not
verified against.

**Naming:** the demo/sandbox vault included here is named `Claude_Sandbox` specifically so it
is never confused with the ChatGPT-produced `DWSIM` / `Nate_Herk` vaults living in Drive.

## What's real vs. what's a skeleton

- **Real and structurally verified:** the full `agent/` + `vaults/_template/` layout, every
  required file the conformance test checks for, the locking/orchestration logic in
  `run-vault.ps1`, the interruption-safe manifest reconciliation in `run-qa.ps1`, the
  scheduler contract and `schedule.csv`-driven dispatch, systemd units.
- **Functionally real but unverified on the actual VM:** `ingest-youtube.ps1` (canonical
  caption logic ported from the documented VM behaviour, but not yet run against the real
  Oracle VM network/proxy setup), `run-claude-synthesis.ps1` (calls the real `claude` CLI,
  untested against your live subscription auth).
- **Explicit placeholders, not hidden:** PDF/DOCX text extraction in
  `ingest-documents.ps1` — see the `[EXTRACTION PENDING]` marker it writes; wire in a real
  extractor before relying on document ingestion.

See `agent/docs/README.md` for the full gap list and `BUILD-REPORT.json` for the conformance
test result this exact package produced.

## Attribution

This project is an independent extension of a publicly shared idea, not an original
concept from scratch. It builds on:

- **Andrej Karpathy** — original concept/gist describing an LLM-driven pipeline that
  turns YouTube video transcripts into structured wiki-style knowledge pages.
  https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
- **Nate Herk** — the YouTube channel whose content was used as the original real-world
  source/proving ground for the single-vault predecessor to this multi-vault build.
  https://www.youtube.com/watch?v=sboNwYmH3AY

This repository is a from-spec, multi-vault rebuild verified against a locked
architecture specification (see `agent/docs/architecture-spec.md`), built independently
of the ChatGPT-produced package it supersedes. It is not affiliated with, endorsed by,
or produced by either of the above.

## YouTube content — copyright and Terms of Service

This pipeline downloads caption/transcript data from YouTube via `yt-dlp` and uses it
as input to an LLM synthesis step. Before pointing this at any channel:

- **You are responsible for your own compliance** with YouTube's Terms of Service and
  applicable copyright law for any channel you configure this against — this includes
  channels you don't own or control. This project does not provide legal advice, and
  using it against content you don't have rights to process is done at your own risk.
- **Intended use is personal reference and curation** — turning a creator's public
  video/transcript content into a private, personal knowledge base that helps you decide
  what's worth your time and how it maps to your own goals, not republishing,
  reposting, or repackaging someone else's content as your own output. That distinction
  matters in practice, not just in principle: a private research/decision-support tool
  and a tool for scraping content to redistribute elsewhere are different activities with
  different risk, even when the underlying code is identical.
- Captions/transcripts, once downloaded, are transformed (cleaned, then synthesized into
  new wiki pages by an LLM) rather than republished verbatim — but the synthesized output
  can still closely track the source material's substance. If you intend to publish or
  share any vault's output beyond personal use, that shifts you toward the
  redistribution end of the spectrum above, and you should weigh ToS/copyright
  obligations accordingly at that point, not assume the transformation alone settles it.
- YouTube's ToS restricts automated access and downloading in ways that can change
  without notice; `yt-dlp` itself is a third-party tool not affiliated with YouTube, and
  its continued function against any given channel is not guaranteed by this project.

## Prerequisites and host setup

Everything below must exist on the host *before* this pipeline will run for real —
none of it is installed automatically by this repository.

1. **Operating system:** Ubuntu Linux (or another `systemd`-based Linux distribution).
   See "Platform support" below — Windows is out of scope for this release.
2. **PowerShell (`pwsh`):** the pipeline scripts are PowerShell, run under PowerShell
   Core on Linux. Install per the official Microsoft instructions for your
   distribution (search "install PowerShell on Ubuntu" for the current apt/snap
   steps — not duplicated here since install commands change across Ubuntu
   releases and this project hasn't re-verified every version).
3. **`yt-dlp`:** used for all YouTube channel scanning and caption downloads.
   Install via your distro's package manager or `pip install yt-dlp`
   (`--break-system-packages` may be required on newer Ubuntu/Debian). Keep it
   updated — YouTube-facing extractors break and get patched frequently upstream.
4. **`rclone`:** used for all Google Drive sync (pull/push) and backup. Install per
   https://rclone.org/install/, then see "Google Drive setup" below for the
   one-time remote configuration this pipeline expects.
5. **Claude Code CLI (`claude`):** see "Claude Code / Claude API authentication"
   below for the two supported auth models and setup steps.
6. **(Optional, only if a configured channel needs it) a proxy:** the production
   use of this pipeline required a WireGuard-based SOCKS5 proxy because the host's
   direct IP was blocked by YouTube — see "YouTube access via VPN/proxy" in
   `agent/docs/README.md`. This is a host-level prerequisite this package does not
   install or manage; only needed if your own host/IP hits the same restriction.

## Google Drive setup

This pipeline treats Google Drive as the canonical, durable store for every vault —
the local `vaults/<n>/` directory on your host is only ever a working copy (see
`sync-vault.ps1`'s own docstring). Before running any vault for real:

1. Configure an `rclone` remote for Google Drive. Run `rclone config`, choose
   "New remote," select the Google Drive backend, and complete the browser OAuth
   flow. **Name the remote exactly `gdrive`** unless you deliberately change every
   vault's `drive_remote` field to match a different name — this repo's `_template`
   and every documented example assume `gdrive`.
2. Decide a Drive folder layout before creating vaults, not after — retrofitting a
   layout once real data exists is real, manual cleanup (this project's own history
   includes exactly that: a backup-path inconsistency between two real vaults that
   had to be found, decided on, and manually migrated after the fact). The
   convention this build uses: `Wikis/<VaultName>/` as each vault's root, with
   backups at `Wikis/<VaultName>/working/backups`.
3. **Do not run `rclone config show gdrive` in any logged/shared session.** It
   prints the remote's OAuth `client_secret` in plaintext to stdout — a real
   credential exposure this project hit directly. If you need to inspect config,
   do it in a private local terminal, never through an AI coding assistant or any
   session whose output might be logged or shared.
4. Set each vault's `config/vault.json` → `drive_remote` and `drive_path` to match
   what you set up here. A mismatch here is silent — the pipeline will simply sync
   against the wrong (or a nonexistent) location with no obvious error.

## Cookie file setup (per-channel, only if needed)

Some YouTube channels require an authenticated session to reliably serve captions
(age-gated, region-restricted, or otherwise rate-limited content) — `vault.json`'s
`cookie_file` field points `yt-dlp` at a real browser-exported cookie file for this.

1. Export cookies from a real logged-in browser session using a cookie-export
   extension (search "export cookies.txt" for your browser — Netscape/Mozilla
   cookie-file format is what `yt-dlp --cookies` expects). This is a manual,
   browser-side step this repository does not automate.
2. Transfer the resulting file to the host **directly** (e.g. `scp`), not through
   an AI coding assistant or any tool that might read, log, or echo its contents.
   This project's own convention: cookie files are never read or displayed by
   Claude Code — only referenced by path.
3. Set `cookie_file` in the relevant vault's `config/vault.json` to the real path
   on the host.
4. Treat the cookie file itself as a credential: keep it out of git (already
   excluded via `.gitignore`'s `vaults/*` pattern), restrict its file permissions,
   and rotate/re-export it if the source browser session's login changes.

## Claude Code / Claude API authentication

`run-claude-synthesis.ps1` calls the `claude` CLI headlessly (`claude -p`). It supports
two different auth models — pick one before running this pipeline for real:

**Subscription auth (Claude Pro/Max), via OAuth — what this project's own VM actually
uses, confirmed empirically through real testing, not assumed:**
1. Install the Claude Code CLI (npm package `@anthropic-ai/claude-code`; requires
   Node.js — see the official install docs for current requirements:
   https://docs.claude.com/en/docs/claude-code/overview).
2. Run `claude` interactively once on the host and complete the browser-based OAuth
   login with your Claude.ai account. This links the CLI to your subscription rather
   than to a billed API key.
3. Usage under this model is governed by your subscription's rolling usage window
   (confirmed in this project's own use: a rolling 5-hour window), **not** a per-call
   dollar cost — which is why `vault.json`'s `claude_budget_usd` field exists as a soft,
   currently-unenforced value in this build: it doesn't apply cleanly to subscription
   billing, and enforcing it meaningfully depends on which auth model you're actually
   running under.
4. Headless/non-interactive invocations (like this pipeline's `claude -p` calls, run via
   cron/systemd with no human present to approve tool use) require an explicit
   permission-mode flag or every tool call is silently denied — this build passes
   `--permission-mode acceptEdits` for that reason. Review what that flag actually
   authorizes before relying on it unattended.

**API key auth — supported by the underlying `claude` CLI, but not the model this
project's own scheduled runs are verified against:**
- Set the `ANTHROPIC_API_KEY` environment variable instead of completing the OAuth
  login. This shifts billing to standard per-token API pricing rather than your
  subscription's usage window.
- If you use this path, `claude_budget_usd` becomes directly meaningful (real dollar
  cost per run) — but its enforcement is still soft/unimplemented in this build as of
  this release; don't assume it will actually stop a run at the configured limit.
- This project has not verified its real end-to-end pipeline behavior under API-key
  billing specifically — only under subscription/OAuth auth. If you use API-key auth,
  treat the budget/cost behavior as unverified until you test it yourself.

For current, authoritative install and auth steps, always check the official docs
directly rather than relying solely on this section:
https://docs.claude.com/en/docs/claude-code/overview

## Quick start

```bash
# 1. Deploy this whole WikiAgent/ folder to the target host (e.g. /home/ubuntu/WikiAgent)
# 2. Copy the template for a new vault:
cp -r vaults/_template vaults/MyNewVault
# 3. Edit vaults/MyNewVault/config/vault.json (channel_url, creator, drive_path, etc.)
# 4. Add one row to agent/scheduling/schedule.csv:
#    MyNewVault,full,Sun,09:00,true
# 5. Install the systemd units and enable the timer:
sudo cp agent/scheduling/ubuntu/systemd/*.service agent/scheduling/ubuntu/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wikiagent.timer
# 6. Verify architecture conformance any time:
pwsh agent/tests/architecture-conformance-test.ps1 -RootPath . -ReportPath conformance-report.json
```

`schedule.csv` only expresses a weekly day/time — for the `lint-review` job type this
maps to a monthly cadence, not weekly; see `agent/docs/schedule-contract.md` for the
exact rule before assuming a lint-review row runs every week.

## Config field reference (`config/vault.json`)

The quick-start's "edit `vault.json`" step undersells how many fields matter. Real
fields from `vaults/_template/config/vault.json`, what each does, and what happens
if you leave it at its template default:

| Field | Purpose | If left blank/default |
|---|---|---|
| `vault_name` | Human-readable vault identifier | Template ships `"REPLACE_ME"` — must be set |
| `channel_url` | YouTube channel this vault ingests from | Blank = YouTube ingestion silently skipped entirely |
| `creator` / `creator_page` | Attribution metadata for the source creator | Cosmetic only — doesn't affect pipeline behavior |
| `max_videos` | Cap on how many channel videos are scanned per run | Defaults to 80 if unset in code, but set it explicitly to match your real channel size |
| `caption_languages` | Preferred caption language(s), in priority order | Defaults to `["en-orig", "en"]` |
| `yt_dlp_path` | Path to the `yt-dlp` binary | Defaults to `yt-dlp` (must resolve on PATH) |
| `proxy` | SOCKS5 proxy URL passed to `yt-dlp --proxy` | Blank = no proxy used; required if your host's IP is blocked by YouTube |
| `cookie_file` | Path to a real exported cookie file | Blank = no auth passed to `yt-dlp`; some channels will fail without it |
| `js_runtime` | JS runtime path some yt-dlp extractors require | Blank unless your channel specifically needs it |
| `drive_remote` | rclone remote name for Drive sync | Must match a remote you actually configured (see "Google Drive setup") |
| `drive_path` | Drive folder path for this vault's canonical copy | Required for any sync/backup to function |
| `claude_effort` | Target synthesis effort passed to the LLM | Vault-defined string, no pipeline-level default enforcement |
| `claude_budget_usd` | Soft per-run budget ceiling | **Currently unenforced regardless of value** — see "Claude Code / Claude API authentication" |
| `max_transcript_attempts` | Retry cap before a caption-failing video is permanently parked | Defaults to `3` if unset |
| `documents.enabled` / `documents.supported_extensions` | Controls manual document ingestion from `input/` | See `agent/docs/README.md`'s "Document ingestion" section before relying on this |
| `backup.enabled` | Whether `backup-vault.ps1` runs at all | `true` in template; set `false` to disable |
| `backup.remote` / `backup.destination` | Where backups get pushed on Drive | Blank destination now auto-derives to `<drive_path>/working/backups` |
| `backup.keep` | Local *and* Drive backup retention count | Defaults to `12`; enforced on both sides as of this release |

## Obsidian — how to actually read the output

This pipeline's terminology (`vault`, `wiki/concepts/`, `wiki/tools/`,
`wiki/workflows/`) directly follows **Obsidian**'s (https://obsidian.md) own
conventions for a linked collection of markdown notes — but nothing in this
repository installs Obsidian, and until now nothing in the documentation said so
explicitly.

- **To view a vault as intended, open its root folder directly in Obsidian**
  (Obsidian → "Open folder as vault"). Every synthesized page is plain markdown
  with YAML frontmatter, so it's readable in any text editor or markdown viewer —
  but cross-references between concepts/tools/workflows are designed around
  Obsidian's linking and graph-view features.
- **Real gap worth knowing before relying on this:** `config/claude.md` (the file
  governing how synthesis output gets written) does not currently give the LLM any
  explicit instruction to use Obsidian's `[[wikilink]]` syntax when cross-referencing
  pages — it only instructs checking for "broken internal links" during lint-review
  without defining the link format itself. This means the actual link syntax
  produced is currently whatever the model defaults to, not a guaranteed,
  enforced convention. Confirm what your own synthesized output actually contains
  before assuming full Obsidian-native linking/graph-view behavior.
- Obsidian itself is free for personal use; check its current licensing directly
  (https://obsidian.md/license) if you intend any commercial or team use of the
  output.

## Platform support

Built and verified against Ubuntu Linux. The pipeline scripts are PowerShell (`pwsh`),
which is technically cross-platform, but scheduling, locking, and deployment all assume
`systemd` — there is no Windows equivalent implemented, tested, or documented in this
release. Windows support is out of scope for this repository; treat it as a candidate
for a separate, future project/fork rather than an assumed capability of what's here
today.

## Upgrade

To upgrade an existing installation in place:

```bash
# 1. Pull the latest commits into the existing clone
cd /path/to/WikiAgent   # e.g. /home/ubuntu/WikiAgent
git pull

# 2. Re-verify architecture conformance against the updated code
pwsh agent/tests/architecture-conformance-test.ps1 -RootPath . -ReportPath conformance-report.json

# 3. Only if the systemd unit files themselves changed in the pulled commits -
#    check first: git diff <old-HEAD> <new-HEAD> -- agent/scheduling/ubuntu/systemd/
#    systemd does not pick up changed unit files on disk automatically, so re-copy
#    and reload/restart if (and only if) that diff is non-empty:
sudo cp agent/scheduling/ubuntu/systemd/*.service agent/scheduling/ubuntu/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart wikiagent.timer
```

`vaults/` is never git-tracked (no deployed vault instance is ever committed — only
`vaults/_template` is), so a plain `git pull` does not touch it: git's merge refuses to
silently overwrite an *untracked* file at a path an incoming commit wants to create or
modify — it aborts with a "would be overwritten by merge" error instead of deleting
anything. Since no upstream commit creates paths under `vaults/DWSIM/`, `vaults/Nate_Herk/`,
or any other deployed vault, that conflict path never arises here in practice. Verified for
real in a disposable scratch clone: hashed every file under a test vault directory, ran
`git pull`, re-hashed — byte-identical (the pull was a no-op fast-forward, since no new
upstream commits existed to pull at verification time; the untracked-path-conflict guarantee
above rests on git's documented merge behavior rather than a fabricated conflict scenario, to
avoid pushing a throwaway commit upstream just to force one).

## Uninstall

There is no automated uninstall script. Uninstalling is a manual operator procedure —
**follow this order exactly**. Skipping step 1 risks **permanently losing any vault data
that hasn't been pushed to Drive yet** — Drive is the canonical store; the local `vaults/`
directory is only ever a working copy (see `agent/scripts/sync-vault.ps1`'s own docstring).

1. **Confirm every vault is fully pushed to Drive first, always:**

   For each deployed vault under `vaults/` (excluding `_template`):
   ```bash
   # Push any pending local state - safe, additive-only (rclone copy, never deletes):
   pwsh agent/scripts/sync-vault.ps1 -VaultRoot vaults/<name> -Direction Push

   # Then confirm nothing local-only remains, using the exact same check
   # sync-vault.ps1 runs internally before every pull:
   rclone check vaults/<name> <drive_remote>:<drive_path> --one-way \
     --exclude '/config/prompts/**' --exclude '/logs/**' --combined -
   ```
   (`<drive_remote>` / `<drive_path>` come from that vault's own `config/vault.json`.) A
   non-zero exit code, or any output line starting with `+` or `*`, means something local is
   not yet on Drive — **do not proceed until this check exits 0 with "0 differences found".**

   Also run `git status` in the repo root and commit or intentionally discard any
   uncommitted code changes you care about — deleting the folder deletes those too.

2. Stop the timer:
   ```bash
   sudo systemctl disable --now wikiagent.timer
   ```
3. Remove the systemd unit files:
   ```bash
   sudo rm /etc/systemd/system/wikiagent.service /etc/systemd/system/wikiagent.timer
   sudo systemctl daemon-reload
   ```
4. Only after steps 1–3: delete the repo folder.
   ```bash
   rm -rf /path/to/WikiAgent
   ```

**Verified for real** (disposable scratch clone + scratch vault, never against real vault
data): pushed a baseline, made an unpushed local edit to simulate the exact risk this
procedure exists to prevent, then ran step 1's check exactly as documented — it correctly
failed (non-zero exit, `* config/vault.json: md5 differ`) *before* any deletion occurred.
Pushing and re-running the check brought it to a clean "0 differences found" exit 0, at which
point deletion would be safe. Confirms the documented check step genuinely stops an operator
before data loss, not just in theory.
