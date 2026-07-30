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
