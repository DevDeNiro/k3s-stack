#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Deletes the local k3d cluster with every workload. By default the persistent
# volume and the generated passwords go too: the next install.sh starts clean.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../vps/scripts/lib/common.sh
source "$SCRIPT_DIR/../vps/scripts/lib/common.sh"

CLUSTER_NAME="dev-cluster"
DATA_VOLUME="k3d-dev-storage"
KEEP_DATA=false

usage() {
    printf '%s\n' \
        "Usage: ./local/uninstall.sh [--keep-data] [-y]" \
        "" \
        "Deletes the k3d cluster '${CLUSTER_NAME}', its volume '${DATA_VOLUME}' (PostgreSQL and" \
        "other persistent data) and the generated passwords local/*_password.txt." \
        "" \
        "  --keep-data  keep the volume and the passwords (they match the stored data)" \
        "  -y, --yes    no confirmation prompt"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-data) KEEP_DATA=true ;;
            -y|--yes) ASSUME_YES=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done

    banner "k3s-stack - local cluster removal"
    confirm "Delete the k3d cluster ${CLUSTER_NAME}$([[ "$KEEP_DATA" == "true" ]] || echo " and its data")?" \
        || die "aborted"

    pkill -f "kubectl.*port-forward" >/dev/null 2>&1 || true
    if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        k3d cluster delete "$CLUSTER_NAME" && ok "Cluster ${CLUSTER_NAME} deleted"
    else
        warn "No k3d cluster ${CLUSTER_NAME}"
    fi

    if [[ "$KEEP_DATA" != "true" ]]; then
        if docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1; then
            docker volume rm "$DATA_VOLUME" >/dev/null && ok "Volume ${DATA_VOLUME} deleted"
        fi
        rm -f "$SCRIPT_DIR"/*_password.txt && ok "Generated passwords deleted"
    fi
}

main "$@"
