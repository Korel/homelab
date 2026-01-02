#!/usr/bin/env bash
set -euo pipefail

# Backup script for homelab environment (Staging Architecture)

# Configuration
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
STAGING_DIR="/data/.backup"
SNAPSHOT_PATH="$STAGING_DIR/docker-volumes"
MOUNTED_DRIVE="/mnt/samsung-hdd"
BACKUP_DIR="$MOUNTED_DRIVE/homelab-backup"
DOCKER_COMPOSE_DIR="/home/korel/projects/homelab"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_DIR/compose.yaml"
BTRFS_SOURCE="/data/docker"
GOTIFY_TOKEN_FILE="/root/backup-job-gotify-token.txt"
HDD_LOG="/var/log/backup-job-hdd.log"
IDRIVE_LOG="/var/log/backup-job-idrive.log"

# Log helper functions
gotify(){
    if [ -z "${GOTIFY_TOKEN:-}" ]; then
        return 0
    fi
    local message="$1"
    local title="${2:-Backup Notification}"
    local priority="${3:-5}"
    local gotify_url="https://gotify.korel.be.eu.org/message?token=$GOTIFY_TOKEN"
    curl -s --max-time 1 -X POST "$gotify_url" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" > /dev/null || true
}

log_info() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1"
}

log_warn() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
  gotify "$1" "Backup Job Warning" 6
}

log_err() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
  gotify "$1" "Backup Job Error" 10
}

log_fatal() {
  log_err "FATAL: $1"
  exit 1
}


# --- Initialization ---
log_info "Starting backup job (Staging Mode)..."

# Load Gotify Token
if [ -f "$GOTIFY_TOKEN_FILE" ]; then
    export GOTIFY_TOKEN=$(cat "$GOTIFY_TOKEN_FILE")
else
    log_warn "Gotify token not found at $GOTIFY_TOKEN_FILE. Notifications disabled."
    export GOTIFY_TOKEN=""
fi

# Ensure staging environment is ready
if [ ! -d "$STAGING_DIR" ]; then
    mkdir -p "$STAGING_DIR" || log_fatal "Could not create staging directory $STAGING_DIR"
fi
mkdir -p "$STAGING_DIR/postgres"

# Cleanup any stale snapshots
if [ -e "$SNAPSHOT_PATH" ]; then
    log_info "Cleaning up stale snapshot..."
    btrfs subvolume delete "$SNAPSHOT_PATH" || log_warn "Failed to delete stale snapshot"
fi

# --- Phase 1: Staging ---

log_info "Creating read-only snapshot of $BTRFS_SOURCE..."
btrfs subvolume snapshot -r "$BTRFS_SOURCE" "$SNAPSHOT_PATH" || log_fatal "Btrfs snapshot failed."

log_info "Creating PostgreSQL dump to staging..."
POSTGRES_DUMP_FILE="$STAGING_DIR/postgres/pg-dumpall-$TIMESTAMP.sql.gz"
docker compose -f "$DOCKER_COMPOSE_FILE" exec -T postgres pg_dumpall -U postgres --clean --if-exists | gzip > "$POSTGRES_DUMP_FILE" || log_err "PostgreSQL dump failed."

# --- Phase 2: Parallel Backup ---

log_info "Starting parallel backup tasks..."

# Task A: Sync to HDD
(
    if mountpoint -q "$MOUNTED_DRIVE"; then
        log_info "--- HDD Sync Started ---"
        mkdir -p "$BACKUP_DIR"
        rsync -av --delete "$STAGING_DIR/" "$BACKUP_DIR/" || log_err "HDD sync failed."
        log_info "--- HDD Sync Completed ---"
    else
        log_warn "HDD not mounted at $MOUNTED_DRIVE. Skipping local backup."
    fi
) >> "$HDD_LOG" 2>&1 &
PID_HDD=$!

# Task B: Push to IDrive
(
    if command -v /opt/IDriveForLinux/bin/idrive &> /dev/null; then
        log_info "--- IDrive Push Started ---"
        /opt/IDriveForLinux/bin/idrive -b --silent || log_err "IDrive backup failed."
        log_info "--- IDrive Push Completed ---"
    else
        log_warn "IDrive binary not found. Skipping cloud backup."
    fi
) 2>&1 | strings >> "$IDRIVE_LOG" &
PID_IDRIVE=$!

# Wait for both
wait $PID_HDD
wait $PID_IDRIVE


# --- Phase 3: Cleanup ---

log_info "Cleaning up staging environment..."
if [ -e "$SNAPSHOT_PATH" ]; then
    btrfs subvolume delete "$SNAPSHOT_PATH" || log_err "Failed to delete snapshot $SNAPSHOT_PATH"
fi

# Keep only 3 days of dumps in staging
find "$STAGING_DIR/postgres" -type f -name "*.sql.gz" -mtime +3 -exec rm {} \;

log_info "Backup job completed successfully."
gotify "Homelab backup successfully staged and synced." "Backup Success" 5
