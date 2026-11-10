#!/bin/bash
# No "set -e": keep removing what remains when one step fails
set -uo pipefail

# =============================================================================
# k3s-stack - removal of what install.sh, setup-gateway-api.sh and onboard-app.sh
# created. Full reinstallation: uninstall.sh --all, then install.sh.
# Always kept: /var/backups/k3s-stack (backups), the UFW firewall, SSH and APT
# hardening (scripts/harden-host.sh).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

UNINSTALL_K3S=false
UNINSTALL_HELM=false
REMOVE_SECRETS=true

# Helm releases, in removal order (<release>:<namespace>)
RELEASES=(
    postgres-backup:storage
    argocd-image-updater:argocd
    argocd:argocd
    sealed-secrets:kube-system
    promtail:monitoring
    loki:monitoring
    grafana:monitoring
    prometheus:monitoring
    postgresql:storage
    cert-manager:cert-manager
    nginx-gateway:nginx-gateway
)
INFRA_NAMESPACES=(storage security monitoring database argocd cert-manager nginx-gateway)

usage() {
    printf '%s\n' \
        "Usage: sudo $0 [--all] [--k3s] [--helm] [--keep-secrets] [--force]" \
        "" \
        "Without option: removes the platform (Helm releases, Keycloak, Redis, Gateway," \
        "ClusterIssuers, CoreDNS hairpin, application and infrastructure namespaces)" \
        "and keeps K3s running." \
        "" \
        "  --k3s           uninstall K3s itself: datastore, /etc/rancher/k3s, every workload" \
        "  --helm          remove the Helm binary" \
        "  --all           --k3s and --helm (full reinstallation)" \
        "  --keep-secrets  keep ${SECRETS_DIR} (generated credentials)" \
        "  --force         no confirmation prompt" \
        "" \
        "Kept: ${BACKUP_DIR}, the UFW firewall, SSH and APT hardening."
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) UNINSTALL_K3S=true; UNINSTALL_HELM=true ;;
            --k3s) UNINSTALL_K3S=true ;;
            --helm) UNINSTALL_HELM=true ;;
            --keep-secrets) REMOVE_SECRETS=false ;;
            --force) ASSUME_YES=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

k3s_running() {
    command -v k3s >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1
}

app_namespaces() {
    kubectl get namespaces -l app.kubernetes.io/managed-by=k3s-stack \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

confirm_uninstall() {
    echo -e "\n${YELLOW}This will remove:${NC}"
    if [[ "$UNINSTALL_K3S" == "true" ]]; then
        echo -e "  - ${RED}K3s and ALL its data (datastore, volumes, every workload)${NC}"
        if ! ls "$BACKUP_DIR"/sealed-secrets/*.enc >/dev/null 2>&1; then
            echo -e "  - ${RED}the Sealed Secrets key, with no backup in $BACKUP_DIR/sealed-secrets:${NC}"
            echo -e "    ${RED}SealedSecrets committed in Git could never be decrypted again.${NC}"
            echo -e "    ${YELLOW}Back it up first: sudo ./vps/scripts/export-secrets.sh backup-sealing-key${NC}"
        fi
    else
        echo -e "  - Helm releases: ${RELEASES[*]%%:*}"
        echo -e "  - Keycloak, Redis, ClusterIssuers, CoreDNS hairpin (coredns-custom)"
        echo -e "  - namespaces: ${INFRA_NAMESPACES[*]} $(app_namespaces | tr '\n' ' ')"
    fi
    echo -e "  - ${RED}the PostgreSQL data and its local dumps (volumes of the namespace storage)${NC}"
    if [[ ! -f "$SECRETS_DIR/offsite-backup.env" ]]; then
        echo -e "    ${YELLOW}No off-site copy is configured: copy the dumps off the server first (vps/docs/postgres-backup.md)${NC}"
    elif [[ "$REMOVE_SECRETS" == "true" ]]; then
        echo -e "    ${YELLOW}The off-site copy needs RESTIC_PASSWORD and the bucket keys, removed with ${SECRETS_DIR}:${NC}"
        echo -e "    ${YELLOW}keep them outside the server first (sudo ./vps/scripts/export-secrets.sh show offsite-backup)${NC}"
    fi
    if [[ "$REMOVE_SECRETS" == "true" ]]; then
        echo -e "  - generated credentials: ${SECRETS_DIR}"
    fi
    if [[ "$UNINSTALL_HELM" == "true" ]]; then
        echo -e "  - the Helm binary"
    fi
    echo ""
    confirm "Continue?" || die "aborted"
}

remove_platform() {
    step "Removing Argo CD applications"
    # The resource types are missing when Argo CD or cert-manager were never installed
    kubectl delete applicationsets --all -n argocd --ignore-not-found --timeout=60s 2>/dev/null || true

    step "Removing Helm releases"
    local entry release namespace
    for entry in "${RELEASES[@]}"; do
        release="${entry%%:*}"
        namespace="${entry##*:}"
        if helm status "$release" -n "$namespace" >/dev/null 2>&1; then
            helm uninstall "$release" -n "$namespace" --wait --timeout 3m >/dev/null && ok "$release removed"
        fi
    done

    step "Removing manifests and cluster-scoped resources"
    # Resource names only: the manifest is rendered without extension image
    # shellcheck disable=SC2119
    render_keycloak_manifest | kubectl delete -f - --ignore-not-found --timeout=120s
    kubectl delete -f "$VPS_MANIFESTS_DIR/redis.yaml" --ignore-not-found --timeout=60s
    kubectl delete clusterissuers letsencrypt-staging letsencrypt-prod --ignore-not-found 2>/dev/null || true
    kubectl delete configmap coredns-custom -n kube-system --ignore-not-found

    step "Removing namespaces"
    local ns
    for ns in $(app_namespaces) "${INFRA_NAMESPACES[@]}"; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            kubectl delete namespace "$ns" --timeout=180s >/dev/null && ok "namespace $ns removed"
        fi
    done

    step "Removing Helm repositories"
    local name
    while read -r name _; do
        helm repo remove "$name" >/dev/null 2>&1 && ok "repository $name removed"
    done < <(grep -Ev '^\s*(#|$)' "$VPS_CONFIG_DIR/helm-repositories")
}

remove_k3s() {
    step "Uninstalling K3s"
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh
        ok "K3s removed (datastore and /etc/rancher/k3s included)"
    else
        warn "K3s uninstall script not found"
    fi
}

main() {
    parse_args "$@"
    banner "k3s-stack - uninstallation"
    require_root
    use_k3s_kubeconfig
    confirm_uninstall

    if [[ "$UNINSTALL_K3S" == "true" ]]; then
        remove_k3s
    elif k3s_running; then
        remove_platform
    else
        warn "K3s is not running: nothing to remove from the cluster"
    fi

    if [[ "$REMOVE_SECRETS" == "true" ]]; then
        rm -rf "$SECRETS_DIR" && ok "$SECRETS_DIR removed"
    fi

    if [[ "$UNINSTALL_HELM" == "true" ]] && command -v helm >/dev/null 2>&1; then
        rm -f "$(command -v helm)" && ok "Helm removed"
    fi

    banner "Uninstallation complete"
    echo -e "Kept: ${BACKUP_DIR}, UFW firewall, SSH and APT hardening."
    echo -e "Reinstall: ${BLUE}sudo ./vps/install.sh${NC}"
}

main "$@"
