# Canonical Linux implementation

This directory is a public-safe implementation derived from an independently
tested Linux deployment. It deliberately retains the observed ingest
behaviour while removing deployment identity and runtime data.

It deliberately includes only the active runtime files:

- four PowerShell scripts from `scripts/linux/`;
- the weekly Bash wrapper;
- backup and restore helpers; and
- the installed systemd service and timer.

It excludes vault content, transcripts, reports, cookies, `.env` files,
rclone configuration, temporary files and all historical script revisions.

## Behavioural reference

The imported updater deliberately requests both `en-orig` and `en` caption
tracks, selects `en-orig` when available (otherwise `en`), and removes the
unselected variant. This is the source behaviour the Windows port must match.
