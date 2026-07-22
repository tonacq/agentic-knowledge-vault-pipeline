#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${WIKI_AGENT_CONFIG:-/etc/wiki-agent/wiki-agent.env}"
if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "ERROR: Runtime configuration not readable: $CONFIG_FILE" >&2
  exit 2
fi
set -a
source "$CONFIG_FILE"
set +a
: "${WIKI_AGENT_ROOT:?Set WIKI_AGENT_ROOT in the runtime configuration.}"
: "${WIKI_AGENT_VAULT:?Set WIKI_AGENT_VAULT in the runtime configuration.}"
: "${WIKI_AGENT_BACKUP_REMOTE:?Set WIKI_AGENT_BACKUP_REMOTE in the runtime configuration.}"

ROOT="$WIKI_AGENT_ROOT"
LOCAL_BACKUP_DIR="$ROOT/backups"
REMOTE_BACKUP_DIR="$WIKI_AGENT_BACKUP_REMOTE"
KEEP_BACKUPS=12
RETENTION_DRY_RUN=false

STAMP="$(date '+%Y%m%d_%H%M%S')"
ARCHIVE_NAME="wiki-agent_backup_${STAMP}.tar.gz"
ARCHIVE_PATH="$LOCAL_BACKUP_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

mkdir -p "$LOCAL_BACKUP_DIR"

echo "Creating backup: $ARCHIVE_PATH"

tar -czf "$ARCHIVE_PATH" \
  -C / \
  "${VAULT#/}" \
  "${ROOT#/}"

sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

echo "Uploading backup to Google Drive..."

rclone copyto \
  "$ARCHIVE_PATH" \
  "$REMOTE_BACKUP_DIR/$ARCHIVE_NAME"

rclone copyto \
  "$CHECKSUM_PATH" \
  "$REMOTE_BACKUP_DIR/$ARCHIVE_NAME.sha256"

echo "Backup completed successfully."
echo "Local:  $ARCHIVE_PATH"
echo "Remote: $REMOTE_BACKUP_DIR/$ARCHIVE_NAME"

echo
echo "=== LOCAL RETENTION CHECK ==="

mapfile -t LOCAL_ARCHIVES < <(
  find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f \
    -name 'wiki-agent_backup_*.tar.gz' \
    -printf '%f\n' |
  sort -r
)

if (( ${#LOCAL_ARCHIVES[@]} > KEEP_BACKUPS )); then
  for archive in "${LOCAL_ARCHIVES[@]:KEEP_BACKUPS}"; do
    if [[ "$RETENTION_DRY_RUN" == true ]]; then
      echo "DRY RUN: would delete local $archive"
      echo "DRY RUN: would delete local $archive.sha256"
    else
      rm -f \
        "$LOCAL_BACKUP_DIR/$archive" \
        "$LOCAL_BACKUP_DIR/$archive.sha256"
      echo "Deleted local $archive and checksum"
    fi
  done
else
  echo "No local backups exceed retention limit."
fi

echo
echo "=== GOOGLE DRIVE RETENTION CHECK ==="

mapfile -t REMOTE_ARCHIVES < <(
  rclone lsf "$REMOTE_BACKUP_DIR" \
    --files-only \
    --include 'wiki-agent_backup_*.tar.gz' |
  sort -r
)

if (( ${#REMOTE_ARCHIVES[@]} > KEEP_BACKUPS )); then
  for archive in "${REMOTE_ARCHIVES[@]:KEEP_BACKUPS}"; do
    if [[ "$RETENTION_DRY_RUN" == true ]]; then
      echo "DRY RUN: would delete remote $archive"
      echo "DRY RUN: would delete remote $archive.sha256"
    else
      rclone deletefile "$REMOTE_BACKUP_DIR/$archive"
      rclone deletefile "$REMOTE_BACKUP_DIR/$archive.sha256"
      echo "Deleted remote $archive and checksum"
    fi
  done
else
  echo "No remote backups exceed retention limit."
fi
