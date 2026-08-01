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
