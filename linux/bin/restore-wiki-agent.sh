#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${WIKI_AGENT_ROOT:-$HOME/wiki-agent}"
BACKUP_DIR="$ROOT/backups"
RESTORE_ROOT="$ROOT/temp/restore-test"

usage() {
  echo "Usage:"
  echo "  $0 <backup-file.tar.gz> [destination]"
  echo
  echo "Default destination:"
  echo "  $RESTORE_ROOT"
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

BACKUP_FILE="$1"
DESTINATION="${2:-$RESTORE_ROOT}"

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: Backup file not found: $BACKUP_FILE"
  exit 1
fi

CHECKSUM_FILE="$BACKUP_FILE.sha256"

if [[ -f "$CHECKSUM_FILE" ]]; then
  echo "Verifying checksum..."
  sha256sum -c "$CHECKSUM_FILE"
else
  echo "WARNING: No checksum file found."
fi

mkdir -p "$DESTINATION"

if [[ -n "$(find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "ERROR: Destination is not empty: $DESTINATION"
  echo "Choose an empty directory."
  exit 1
fi

echo "Restoring backup into:"
echo "  $DESTINATION"

tar -xzf "$BACKUP_FILE" -C "$DESTINATION"

echo
echo "Restore completed."
echo "Restored files are under:"
echo "  $DESTINATION/<agent-root>/"
echo "  $DESTINATION/etc/systemd/system/"
echo "  $DESTINATION/etc/logrotate.d/"
