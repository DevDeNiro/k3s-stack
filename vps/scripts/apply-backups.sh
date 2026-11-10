#!/bin/bash
set -euo pipefail

# =============================================================================
# PostgreSQL backup CronJobs: Helm chart vps/postgres-backup, namespace storage
#   - daily, weekly and monthly dumps on the backup volume, made with the image
#     of the server (values/postgresql-image.yaml)
#   - with OFFSITE_BACKUP_REPOSITORY (config.env): encrypted restic copy of the
#     dumps to an S3-compatible object storage and a weekly check
#     (templates/postgres-backup/offsite-values.yaml.tpl, RESTIC_VERSION of
#     config/versions.env, credentials: setup-secrets.sh set-offsite-backup)
# Called by install.sh; run it again after changing the off-site settings or the
# chart (removing OFFSITE_BACKUP_REPOSITORY removes the off-site CronJobs).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../config/versions.env
source "$VPS_CONFIG_DIR/versions.env"

RELEASE="postgres-backup"
CHART_DIR="$K3S_STACK_VPS_DIR/postgres-backup"
DRY_RUN=false

usage() {
    printf '%s\n' \
        "Usage: [sudo] $0 [--dry-run]" \
        "" \
        "Installs or upgrades the PostgreSQL backup CronJobs (vps/postgres-backup, namespace" \
        "storage), with the off-site restic copy when OFFSITE_BACKUP_REPOSITORY is set in" \
        "vps/config.env (root required to apply)." \
        "" \
        "  --dry-run  print the rendered manifests (helm template) without applying them"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

offsite_enabled() {
    [[ -n "${OFFSITE_BACKUP_REPOSITORY:-}" ]]
}

render_offsite_values() {
    render_template "$VPS_TEMPLATES_DIR/postgres-backup/offsite-values.yaml.tpl" \
        "OFFSITE_BACKUP_REPOSITORY=$OFFSITE_BACKUP_REPOSITORY" \
        "OFFSITE_BACKUP_REGION=${OFFSITE_BACKUP_REGION:-}" \
        "OFFSITE_BACKUP_SECRET=$OFFSITE_BACKUP_SECRET" RESTIC_VERSION
}

# run_helm <helm command>...: runs the command with the values of the release,
# the off-site values on stdin when the copy is configured
run_helm() {
    if offsite_enabled; then
        render_offsite_values | "$@" -f "$VPS_VALUES_DIR/postgresql-image.yaml" -f -
    else
        "$@" -f "$VPS_VALUES_DIR/postgresql-image.yaml"
    fi
}

main() {
    parse_args "$@"
    if [[ "$DRY_RUN" != "true" ]]; then
        require_root
    fi
    load_config
    validate_offsite_config
    require_commands helm

    if [[ "$DRY_RUN" == "true" ]]; then
        run_helm helm template "$RELEASE" "$CHART_DIR" --namespace "$PG_NAMESPACE"
        return 0
    fi

    use_k3s_kubeconfig
    if offsite_enabled; then
        step "PostgreSQL backups: local dumps and off-site copy (restic ${RESTIC_VERSION})"
    else
        step "PostgreSQL backups: local dumps (no off-site copy: OFFSITE_BACKUP_REPOSITORY is empty)"
    fi
    # No --wait: the backup PVC binds when the first job runs (WaitForFirstConsumer)
    run_helm helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$PG_NAMESPACE"
    ok "CronJobs: $(kubectl get cronjobs -n "$PG_NAMESPACE" -l app.kubernetes.io/name=postgres-backup \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"

    if offsite_enabled; then
        if ! kubectl get secret "$OFFSITE_BACKUP_SECRET" -n "$PG_NAMESPACE" >/dev/null 2>&1; then
            warn "No Secret $PG_NAMESPACE/$OFFSITE_BACKUP_SECRET: the off-site jobs fail until it exists."
            echo "  Run: sudo ./vps/scripts/setup-secrets.sh set-offsite-backup"
        fi
        echo "First copy now (creates the repository): kubectl create job --from=cronjob/${RELEASE}-offsite \\"
        echo "  ${RELEASE}-offsite-\$(date +%s) -n $PG_NAMESPACE   (vps/docs/postgres-backup.md)"
    fi
}

main "$@"
