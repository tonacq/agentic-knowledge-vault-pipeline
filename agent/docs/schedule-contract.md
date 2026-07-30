# `schedule.csv` contract

Location: `agent/scheduling/schedule.csv`

| column        | required | values                          | notes |
|---------------|----------|----------------------------------|-------|
| vault_name    | yes      | must match a directory under `vaults/` (not `_template`) | case-sensitive |
| job_type      | yes      | `full` \| `lint-review`          | see `01-architecture-spec.md` §5 and vault `config/claude.md` |
| day_of_week   | yes      | `Mon`..`Sun`                      | UTC |
| time_utc      | yes      | `HH:MM`, 24h, UTC                 | matched to the hour by the hourly systemd timer |
| enabled       | yes      | `true` \| `false`                 | `false` rows are ignored entirely |

## To onboard a new vault (the whole point of this design)

1. Copy `vaults/_template/` to `vaults/<NewVaultName>/`.
2. Edit `vaults/<NewVaultName>/config/vault.json` (channel URL, creator, Drive path, etc).
3. Add one row to `agent/scheduling/schedule.csv` with `vault_name = <NewVaultName>` and
   `enabled = true`.
4. Nothing else changes. `agent/` is never touched for a new vault. The scheduler
   (`agent/scheduling/ubuntu/run-wikiagent.sh`) discovers the new row automatically on its
   next hourly tick.

## Duplicate-run prevention

`run-vault.ps1` takes a per-vault lock (`agent/scheduling/locks/<vault>.lock`) before doing
anything, so even if the scheduler fires twice for the same vault (e.g. a long-running job
still active at the next hourly tick), the second invocation aborts immediately rather than
running concurrently against the same manifest.
