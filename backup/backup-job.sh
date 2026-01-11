#!/usr/bin/env bash
set -euo pipefail

# Backup script for homelab environment (Staging Architecture)

# Configuration
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
STAGING_DIR=${STAGING_DIR:-"/data/.backup"}
SNAPSHOT_DIR=${SNAPSHOT_DIR:-"$STAGING_DIR/snapshots"}
HDD_MOUNTED_DRIVE=${HDD_MOUNTED_DRIVE:-"/mnt/samsung-hdd"}
HDD_BACKUP_DIR=${HDD_BACKUP_DIR:-"$HDD_MOUNTED_DRIVE/homelab-backup"}
DOCKER_COMPOSE_DIR=${DOCKER_COMPOSE_DIR:-"/home/korel/projects/homelab"}
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_DIR/compose.yaml"
GOTIFY_TOKEN_FILE=${GOTIFY_TOKEN_FILE:-"/root/backup-job-gotify-token.txt"}
LOG_DIR=${LOG_DIR:-"/var/log"}
BACKUP_JOB_LOG=${BACKUP_JOB_LOG:-"$LOG_DIR/backup-job.log"}
HDD_LOG=${HDD_LOG:-"$LOG_DIR/backup-job-hdd.log"}
IDRIVE_LOG=${IDRIVE_LOG:-"$LOG_DIR/backup-job-idrive.log"}
BTRFS_SNAPSHOT_DIRS=(
    "/data/docker"
    "/data/personal"
)

log_info() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1"
}

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
        -F "priority=$priority" > /dev/null || echo "ERROR: Gotify notification failed to send." >&2 # Using echo to avoid recursion
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

# Check if log file can be created/written into
if { true >> "$BACKUP_JOB_LOG"; }; then    
    # Setup logging of this script to BACKUP_JOB_LOG
    log_info "The logs for this backup job will be stored in: $BACKUP_JOB_LOG"
    exec >> "$BACKUP_JOB_LOG" 2>&1
else
    log_warn "Cannot write to log file $BACKUP_JOB_LOG. Logging to stdout."
fi

log_info "Starting backup job (Staging Mode)..."

# Load Gotify Token
if [ -f "$GOTIFY_TOKEN_FILE" ]; then
    GOTIFY_TOKEN=$(cat "$GOTIFY_TOKEN_FILE") || log_warn "Could not read Gotify token from $GOTIFY_TOKEN_FILE. Notifications disabled."
else
    log_warn "Gotify token not found at $GOTIFY_TOKEN_FILE. Notifications disabled."
fi
export GOTIFY_TOKEN=${GOTIFY_TOKEN:-""}

# Ensure staging environment is ready
if [ ! -d "$STAGING_DIR" ]; then
    mkdir -p "$STAGING_DIR" || log_fatal "Could not create staging directory $STAGING_DIR"
fi
mkdir -p "$STAGING_DIR/postgres"

# Cleanup any stale snapshots
log_info "Cleaning up any stale Btrfs snapshots in staging..."
for SOURCE in "${BTRFS_SNAPSHOT_DIRS[@]}"; do
    SNAPSHOT_NAME=$(basename "$SOURCE")
    SNAPSHOT_PATH="$STAGING_DIR/$SNAPSHOT_NAME"
    if [ -d "$SNAPSHOT_PATH" ]; then
        log_info "Cleaning up stale snapshot $SNAPSHOT_PATH..."
        btrfs subvolume delete "$SNAPSHOT_PATH" || log_fatal "Failed to delete stale snapshot $SNAPSHOT_PATH"
    fi
done

# --- Phase 1: Staging ---

log_info "Creating Btrfs snapshots for '${BTRFS_SNAPSHOT_DIRS[*]}' staging..."
for SOURCE in "${BTRFS_SNAPSHOT_DIRS[@]}"; do
    SNAPSHOT_NAME=$(basename "$SOURCE")
    SNAPSHOT_PATH="$STAGING_DIR/$SNAPSHOT_NAME"
    log_info "Creating read-only snapshot of $SOURCE..."
    btrfs subvolume snapshot -r "$SOURCE" "$SNAPSHOT_PATH" || log_fatal "Btrfs snapshot failed for $SOURCE."
done

log_info "Creating PostgreSQL dump to staging..."
POSTGRES_DUMP_FILE="$STAGING_DIR/postgres/pg-dumpall-$TIMESTAMP.sql.gz"
if docker compose -f "$DOCKER_COMPOSE_FILE" exec -T postgres pg_dumpall -U postgres --clean --if-exists | gzip > "$POSTGRES_DUMP_FILE"; then 
    find "$STAGING_DIR/postgres" -type f -name "*.sql.gz" -mtime +3 -exec rm {} \; # Cleanup dumps older than 3 days
    log_info "PostgreSQL dump created at $POSTGRES_DUMP_FILE."
else
    log_err "PostgreSQL dump failed."
fi

# --- Phase 2: Parallel Backup ---

log_info "Starting parallel backup tasks..."

# Task A: Sync to HDD
(
    if mountpoint -q "$HDD_MOUNTED_DRIVE"; then
        log_info "--- HDD Sync Started ---"
        mkdir -p "$HDD_BACKUP_DIR"
        if rsync -av --delete "$STAGING_DIR/" "$HDD_BACKUP_DIR/"; then
            log_info "--- HDD Sync Completed ---"
        else
            log_err "HDD sync failed!"
        fi
        
    else
        log_warn "HDD not mounted at $HDD_MOUNTED_DRIVE. Skipping local backup."
    fi
) >> "$HDD_LOG" 2>&1 &
PID_HDD=$!

# Task B: Push to IDrive
(
    if command -v /opt/IDriveForLinux/bin/idrive &> /dev/null; then
        log_info "--- IDrive Push Started ---"
        if /opt/IDriveForLinux/bin/idrive -b --silent; then
            log_info "--- IDrive Push Completed ---"
        else
            log_err "IDrive backup failed!"
        fi
    else
        log_err "IDrive binary not found. Skipping cloud backup."
    fi
) 2>&1 | strings >> "$IDRIVE_LOG" &
PID_IDRIVE=$!

# Wait for both
wait $PID_HDD
wait $PID_IDRIVE


# --- Phase 3: Cleanup ---

log_info "Cleaning up staging environment..."
for SOURCE in "${BTRFS_SNAPSHOT_DIRS[@]}"; do
    SNAPSHOT_NAME=$(basename "$SOURCE")
    SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT_NAME"
    if [ -d "$SNAPSHOT_PATH" ]; then
        btrfs subvolume delete "$SNAPSHOT_PATH" || log_err "Failed to delete snapshot $SNAPSHOT_PATH"
    fi
done

log_info "Backup job completed successfully."
gotify "Homelab backup successfully staged and synced." "Backup Success" 5
