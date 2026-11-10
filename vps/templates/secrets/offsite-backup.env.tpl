# =============================================================================
# k3s-stack off-site backup credentials (restic) - saved on ${SAVED_AT}
# Written by vps/scripts/setup-secrets.sh set-offsite-backup into
# /root/.k3s-secrets/offsite-backup.env (root only) and pushed as the Secret
# storage/${OFFSITE_BACKUP_SECRET}. Read line by line, never sourced.
# Keep RESTIC_PASSWORD in a password manager too: without it the off-site
# backups can never be decrypted.
# Display: sudo ./vps/scripts/export-secrets.sh show offsite-backup
# =============================================================================
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
RESTIC_PASSWORD=${RESTIC_PASSWORD}
