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
: "${WIKI_AGENT_REMOTE:?Set WIKI_AGENT_REMOTE in the runtime configuration.}"

export PATH="${WIKI_AGENT_PATH:-$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin}"
ROOT="$WIKI_AGENT_ROOT"
VAULT="$WIKI_AGENT_VAULT"
SYSTEM_SCRIPTS="$ROOT/linux/scripts"
LOG_DIR="$ROOT/logs"
LOCK_FILE="$ROOT/temp/wiki-agent-weekly.lock"
REMOTE="$WIKI_AGENT_REMOTE"
PIPELINE="$VAULT/scripts/run_weekly_agentic_pipeline_v2_linux.ps1"

mkdir -p "$LOG_DIR" "$ROOT/temp"

STAMP="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="$LOG_DIR/wiki-agent-weekly_$STAMP.log"

send_telegram() {
    local message="$1"

    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -sS -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            >/dev/null || true
    fi
}

exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "Wiki-agent weekly pipeline"
echo "Started: $(date --iso-8601=seconds)"
echo "Log: $LOG_FILE"
echo "========================================"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "ERROR: Another weekly pipeline run is already active."

    send_telegram "❌ Wiki-agent pipeline did not start
Reason: another run is already active
Time: $(date --iso-8601=seconds)"

    exit 1
fi

on_error() {
    exit_code=$?

    echo "ERROR: Pipeline failed with exit code $exit_code"
    echo "Stopped: $(date --iso-8601=seconds)"

    send_telegram "❌ Wiki-agent pipeline failed
Exit code: $exit_code
Time: $(date --iso-8601=seconds)
Log: $LOG_FILE"

    exit "$exit_code"
}

trap on_error ERR

echo
echo "[1/5] Syncing Google Drive to VM..."

rclone sync \
    "$REMOTE" \
    "$VAULT" \
    --exclude "/scripts/*_linux.ps1" \
    --progress

echo
echo "[2/5] Installing Linux script overlay..."

cp "$SYSTEM_SCRIPTS/weekly_update_channel_wiki_v8_linux.ps1" \
   "$VAULT/scripts/"

cp "$SYSTEM_SCRIPTS/post_synthesis_completion_v1_linux.ps1" \
   "$VAULT/scripts/"

cp "$SYSTEM_SCRIPTS/qa_reconcile_sources_v3_linux.ps1" \
   "$VAULT/scripts/"

cp "$SYSTEM_SCRIPTS/run_weekly_agentic_pipeline_v2_linux.ps1" \
   "$VAULT/scripts/"

echo
echo "[3/5] Creating pre-run backup..."

"$ROOT/linux/bin/backup-wiki-agent.sh"

echo
echo "[4/5] Running weekly pipeline..."

cd "$VAULT"

/usr/local/bin/pwsh -NoProfile -File "$PIPELINE" \
    -VaultRoot "$VAULT"

echo
echo "[5/5] Copying successful changes to Google Drive..."

rclone copy \
    "$VAULT" \
    "$REMOTE" \
    --exclude "/scripts/*_linux.ps1" \
    --progress

ln -sfn "$LOG_FILE" "$LOG_DIR/latest-wiki-agent-weekly.log"

send_telegram "✅ Wiki-agent pipeline completed successfully
Time: $(date --iso-8601=seconds)
Log: $LOG_FILE"

echo
echo "========================================"
echo "Pipeline completed successfully"
echo "Finished: $(date --iso-8601=seconds)"
echo "========================================"
