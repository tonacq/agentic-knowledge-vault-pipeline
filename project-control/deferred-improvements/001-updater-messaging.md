# Deferred Improvement 001 — Updater Messaging

## Status

Deferred — low priority.

## Summary

Improve the Linux weekly updater messaging during transcript retry and fallback processing.

## Impact

Cosmetic only. No known functional defect. The validated pipeline remains unchanged.

## Implementation trigger

Address this item only when a future functional change already requires updates to either:

- `linux/scripts/weekly_update_channel_wiki_v8_linux.ps1`
- `linux/scripts/run_weekly_agentic_pipeline_v2_linux.ps1`

## Future work

When triggered:

1. Improve the relevant console and report wording.
2. Create the next version of the updater.
3. Version the pipeline wrapper if its dependency changes.
4. Update launcher and documentation references where required.
5. Test the complete VM pipeline before deployment.

## Decision

Do not initiate a standalone release solely for this messaging change.
