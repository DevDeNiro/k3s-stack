#!/bin/bash
set -euo pipefail

# =============================================================================
# PostgreSQL Backup Script
# Performs pg_dump with 30-day retention
# Designed to run inside a Kubernetes CronJob
# =============================================================================

# Configuration (override via environment variables)
POSTGRES_HOST="${POSTGRES_HOST:-postgresql.storage.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-appuser}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Timestamp for backup file
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="${BACKUP_DIR}/${POSTGRES_DB}_${TIMESTAMP}.dump"
BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check pg_dump is available
    if ! command -v pg_dump &> /dev/null; then
        log_error "pg_dump not found. Ensure PostgreSQL client is installed."
        exit 1
    fi
    
    # Check backup directory exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "Creating backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi
    
    # Check PostgreSQL connectivity
    if ! PGPASSWORD="$PGPASSWORD" pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" &> /dev/null; then
        log_error "Cannot connect to PostgreSQL at $POSTGRES_HOST:$POSTGRES_PORT"
        exit 1
    fi
    
    log_info "Pre-flight checks passed."
}

# -----------------------------------------------------------------------------
# Perform backup
# -----------------------------------------------------------------------------
perform_backup() {
    log_info "Starting backup of database: $POSTGRES_DB"
    log_info "Host: $POSTGRES_HOST:$POSTGRES_PORT"
    log_info "Output: $BACKUP_FILE_COMPRESSED"
    
    # Perform pg_dump with custom format (best for restoration)
    if PGPASSWORD="$PGPASSWORD" pg_dump \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        -Fc \
        --verbose \
        --no-owner \
        --no-acl \
        -f "$BACKUP_FILE"; then
        
        log_info "pg_dump completed successfully."
        
        # Compress the backup
        log_info "Compressing backup..."
        gzip -f "$BACKUP_FILE"
        
        # Get backup size
        BACKUP_SIZE=$(du -h "$BACKUP_FILE_COMPRESSED" | cut -f1)
        log_info "Backup completed: $BACKUP_FILE_COMPRESSED ($BACKUP_SIZE)"
        
    else
        log_error "pg_dump failed!"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Verify backup
# -----------------------------------------------------------------------------
verify_backup() {
    log_info "Verifying backup integrity..."
    
    # Check file exists and has content
    if [[ ! -s "$BACKUP_FILE_COMPRESSED" ]]; then
        log_error "Backup file is empty or doesn't exist!"
        exit 1
    fi
    
    # Test gzip integrity
    if gzip -t "$BACKUP_FILE_COMPRESSED" 2>/dev/null; then
        log_info "Backup verification passed (gzip integrity OK)."
    else
        log_error "Backup verification failed (gzip corrupted)!"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Cleanup old backups
# -----------------------------------------------------------------------------
cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    
    # Find and delete old backups
    deleted_count=$(find "$BACKUP_DIR" -name "*.dump.gz" -type f -mtime +$RETENTION_DAYS -delete -print | wc -l)
    
    if [[ $deleted_count -gt 0 ]]; then
        log_info "Deleted $deleted_count old backup(s)."
    else
        log_info "No old backups to delete."
    fi
    
    # Show remaining backups
    log_info "Current backups:"
    ls -lh "$BACKUP_DIR"/*.dump.gz 2>/dev/null || log_warn "No backups found."
}

# -----------------------------------------------------------------------------
# Generate backup report
# -----------------------------------------------------------------------------
generate_report() {
    log_info "=== Backup Report ==="
    echo "Database: $POSTGRES_DB"
    echo "Host: $POSTGRES_HOST:$POSTGRES_PORT"
    echo "Backup File: $BACKUP_FILE_COMPRESSED"
    echo "Backup Size: $(du -h "$BACKUP_FILE_COMPRESSED" | cut -f1)"
    echo "Retention: $RETENTION_DAYS days"
    echo "Total Backups: $(ls -1 "$BACKUP_DIR"/*.dump.gz 2>/dev/null | wc -l)"
    echo "Disk Usage: $(du -sh "$BACKUP_DIR" | cut -f1)"
    log_info "====================="
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_info "=== PostgreSQL Backup Script Started ==="
    
    preflight_checks
    perform_backup
    verify_backup
    cleanup_old_backups
    generate_report
    
    log_info "=== Backup Script Completed Successfully ==="
}

main "$@"
