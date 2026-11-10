# =============================================================================
# Off-site copy of the PostgreSQL dumps: values of the vps/postgres-backup chart
# Rendered by vps/scripts/apply-backups.sh when OFFSITE_BACKUP_REPOSITORY is set
# in config.env; restic version: RESTIC_VERSION of config/versions.env.
# =============================================================================
offsite:
    enabled: true
    repository: "${OFFSITE_BACKUP_REPOSITORY}"
    region: "${OFFSITE_BACKUP_REGION}"
    existingSecret: "${OFFSITE_BACKUP_SECRET}"
    image:
        tag: "${RESTIC_VERSION}"
