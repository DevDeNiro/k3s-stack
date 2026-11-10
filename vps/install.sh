#!/bin/bash
set -euo pipefail

# =============================================================================
# k3s-stack - installation on a fresh Ubuntu/Debian VPS
#
# Installs K3s and the platform services. Configuration lives in files:
#   vps/config.env      site settings (copy of config.env.example)
#   vps/config/         versions, K3s flags, audit policy, Helm repositories
#   vps/values/         Helm values
#   vps/manifests/      static manifests
#   vps/templates/      manifests rendered from config.env
# Keycloak, the GitOps configuration and the backups are applied by the scripts
# that also update them later: scripts/apply-keycloak.sh, apply-config.sh and
# apply-backups.sh.
# Changing a major setting means a reinstallation: uninstall.sh --all, then install.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# Versions: K3S_VERSION, NGINX_GATEWAY_FABRIC_VERSION, <COMPONENT>_VERSION...
# shellcheck source=config/versions.env
source "$VPS_CONFIG_DIR/versions.env"

# Host hardening (scripts/harden-host.sh)
INSTALL_FIREWALL="${INSTALL_FIREWALL:-true}"
AUTO_UPDATES="${AUTO_UPDATES:-true}"
ALLOW_API_FROM="${ALLOW_API_FROM:-}"

# Components
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"
INSTALL_POSTGRESQL="${INSTALL_POSTGRESQL:-true}"
INSTALL_KEYCLOAK="${INSTALL_KEYCLOAK:-true}"
INSTALL_REDIS="${INSTALL_REDIS:-true}"
INSTALL_PROMETHEUS="${INSTALL_PROMETHEUS:-true}"
INSTALL_GRAFANA="${INSTALL_GRAFANA:-true}"
INSTALL_LOKI="${INSTALL_LOKI:-true}"
INSTALL_PROMTAIL="${INSTALL_PROMTAIL:-true}"
INSTALL_SEALED_SECRETS="${INSTALL_SEALED_SECRETS:-true}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
INSTALL_NETWORK_POLICIES="${INSTALL_NETWORK_POLICIES:-true}"

usage() {
    printf '%s\n' \
        "Usage: sudo $0" \
        "" \
        "Installs K3s and the platform services on a fresh VPS (see vps/README.md)." \
        "Requires vps/config.env (cp vps/config.env.example vps/config.env)." \
        "" \
        "Environment variables (defaults in brackets):" \
        "  K3S_VERSION, *_VERSION        versions of vps/config/versions.env [K3s $K3S_VERSION]" \
        "  INSTALL_FIREWALL              UFW firewall, Kubernetes API closed [true]" \
        "  AUTO_UPDATES                  unattended security updates [true]" \
        "  ALLOW_API_FROM                CIDRs allowed on 6443, space-separated [none]" \
        "  INSTALL_<COMPONENT>           true|false, components: CERT_MANAGER POSTGRESQL KEYCLOAK" \
        "                                REDIS PROMETHEUS GRAFANA LOKI PROMTAIL SEALED_SECRETS" \
        "                                ARGOCD NETWORK_POLICIES [true]"
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
check_system() {
    step "Checking the system"
    command -v apt-get >/dev/null 2>&1 || die "an apt-based distribution is required (Ubuntu, Debian)"
    require_supported_k3s "$K3S_VERSION"
    # shellcheck source=/dev/null
    ok "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"

    local total_ram
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    ok "RAM: ${total_ram}MB, disk free: $(df -h / | awk 'NR==2 {print $4}')"
    if [[ $total_ram -lt 3500 ]]; then
        warn "Less than 4GB RAM: some services may not start"
    fi

    if [[ "$INSTALL_KEYCLOAK" == "true" && "$INSTALL_POSTGRESQL" != "true" ]]; then
        die "Keycloak needs PostgreSQL (INSTALL_POSTGRESQL=true)"
    fi
}

install_dependencies() {
    step "Installing dependencies"
    apt_update
    # gettext-base: envsubst (templates), apache2-utils: htpasswd (Argo CD password hash),
    # iptables before K3s: K3s, flannel and UFW must write to the same iptables backend
    apt_install curl git jq openssl ca-certificates gettext-base apache2-utils iptables
    ok "Dependencies installed"
}

# -----------------------------------------------------------------------------
# K3s and host
# -----------------------------------------------------------------------------
install_k3s() {
    step "Installing K3s ${K3S_VERSION}"
    if command -v k3s >/dev/null 2>&1; then
        ok "K3s already installed: $(k3s --version | head -1)"
        warn "Its configuration is not changed: reinstall (uninstall.sh --all) to apply config/k3s/"
        return 0
    fi

    install -D -m 600 "$VPS_CONFIG_DIR/k3s/config.yaml" /etc/rancher/k3s/config.yaml
    install -D -m 600 "$VPS_CONFIG_DIR/k3s/audit-policy.yaml" /var/lib/rancher/k3s/server/audit/policy.yaml
    install -d -m 700 /var/log/kubernetes/audit

    # No installer argument: every flag lives in /etc/rancher/k3s/config.yaml
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -

    until kubectl get nodes >/dev/null 2>&1; do
        sleep 5
    done
    kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
    ok "K3s running, secrets encrypted at rest"
}

harden_host() {
    if [[ "$INSTALL_FIREWALL" != "true" ]]; then
        warn "Skipping host hardening (INSTALL_FIREWALL=false)"
        return 0
    fi
    local args=(--apply --yes) cidr
    if [[ "$AUTO_UPDATES" == "true" ]]; then
        args+=(--auto-updates)
    fi
    for cidr in $ALLOW_API_FROM; do
        args+=(--allow-api-from "$cidr")
    done
    bash "$SCRIPT_DIR/scripts/harden-host.sh" "${args[@]}"
}

install_helm() {
    step "Installing Helm"
    if command -v helm >/dev/null 2>&1; then
        ok "Helm already installed: $(helm version --short)"
        return 0
    fi
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

setup_helm_repos() {
    step "Configuring Helm repositories"
    local name url
    while read -r name url; do
        helm repo add "$name" "$url" --force-update >/dev/null
    done < <(grep -Ev '^\s*(#|$)' "$VPS_CONFIG_DIR/helm-repositories")
    helm repo update >/dev/null
    ok "Helm repositories ready"
}

create_namespaces() {
    step "Creating infrastructure namespaces"
    kubectl apply -f "$VPS_NAMESPACES_DIR/"
}

setup_secrets() {
    bash "$SCRIPT_DIR/scripts/setup-secrets.sh" setup
}

# -----------------------------------------------------------------------------
# Traffic and certificates
# -----------------------------------------------------------------------------
# The Gateway API CRDs come with K3s (gateway-api-crd component). The NGF chart
# creates the "nginx" GatewayClass and its NginxProxy parameters (hostPorts
# 80/443). The Gateway itself comes from setup-gateway-api.sh.
install_gateway_api() {
    step "Installing NGINX Gateway Fabric ${NGINX_GATEWAY_FABRIC_VERSION}"
    wait_gateway_api_crds
    helm upgrade --install nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
        --version "$NGINX_GATEWAY_FABRIC_VERSION" \
        --namespace nginx-gateway \
        -f "$VPS_VALUES_DIR/nginx-gateway-fabric.yaml" \
        --wait --timeout 5m
    ok "NGINX Gateway Fabric ready (GatewayClass nginx)"
}

install_cert_manager() {
    if [[ "$INSTALL_CERT_MANAGER" != "true" ]]; then
        warn "Skipping cert-manager (INSTALL_CERT_MANAGER=false)"
        return 0
    fi
    step "Installing cert-manager ${CERT_MANAGER_VERSION}"
    helm upgrade --install cert-manager jetstack/cert-manager \
        --version "$CERT_MANAGER_VERSION" \
        --namespace cert-manager \
        -f "$VPS_VALUES_DIR/cert-manager.yaml" \
        --wait --timeout 5m

    # The webhook serves its certificate a few seconds after the rollout
    local issuers
    issuers=$(render_template "$VPS_TEMPLATES_DIR/cert-manager/cluster-issuers.yaml.tpl" LETSENCRYPT_EMAIL)
    for _ in $(seq 1 11); do
        if printf '%s\n' "$issuers" | kubectl apply -f - >/dev/null 2>&1; then
            ok "ClusterIssuers letsencrypt-staging and letsencrypt-prod ready"
            return 0
        fi
        sleep 5
    done
    printf '%s\n' "$issuers" | kubectl apply -f -
}

# -----------------------------------------------------------------------------
# Data and identity
# -----------------------------------------------------------------------------
install_postgresql() {
    if [[ "$INSTALL_POSTGRESQL" != "true" ]]; then
        warn "Skipping PostgreSQL (INSTALL_POSTGRESQL=false)"
        return 0
    fi
    step "Installing PostgreSQL"
    helm upgrade --install postgresql bitnami/postgresql \
        --version "$POSTGRESQL_CHART_VERSION" \
        --namespace storage \
        -f "$VPS_VALUES_DIR/postgresql.yaml" \
        -f "$VPS_VALUES_DIR/postgresql-image.yaml" \
        --wait --timeout 5m
    ok "PostgreSQL running: postgresql.storage.svc.cluster.local:5432"
}

create_keycloak_database() {
    if [[ "$INSTALL_KEYCLOAK" != "true" ]]; then
        return 0
    fi
    step "Creating the Keycloak database"
    pg_wait_ready 300s
    local password
    password=$(secret_value security keycloak-db-secret password)
    [[ -n "$password" ]] || die "secret security/keycloak-db-secret not found"
    pg_admin_exec "$VPS_SQL_DIR/ensure-role-database.sql" \
        role=keycloak "password=$password" database=keycloak reset_password=true
    ok "Database keycloak ready"
}

install_keycloak() {
    if [[ "$INSTALL_KEYCLOAK" != "true" ]]; then
        warn "Skipping Keycloak (INSTALL_KEYCLOAK=false)"
        return 0
    fi
    step "Installing Keycloak"
    # templates/keycloak/, with the extension images of KEYCLOAK_EXTENSION_IMAGES
    bash "$SCRIPT_DIR/scripts/apply-keycloak.sh" --no-restart
}

install_redis() {
    if [[ "$INSTALL_REDIS" != "true" ]]; then
        warn "Skipping Redis (INSTALL_REDIS=false)"
        return 0
    fi
    step "Installing Redis"
    kubectl apply -f "$VPS_MANIFESTS_DIR/redis.yaml"
    kubectl rollout status deployment/redis -n database --timeout=120s \
        || warn "Redis is still starting: kubectl get pods -n database"
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------
# helm_install <flag> <release> <chart> <version> <values-file> <timeout>
helm_install() {
    local flag="$1" release="$2" chart="$3" version="$4" values="$5" timeout="$6"
    if [[ "${!flag}" != "true" ]]; then
        warn "Skipping ${release} (${flag}=false)"
        return 0
    fi
    step "Installing ${release} (chart ${version})"
    helm upgrade --install "$release" "$chart" \
        --version "$version" \
        --namespace monitoring \
        -f "$VPS_VALUES_DIR/$values" \
        --wait --timeout "$timeout"
}

install_observability() {
    # 10m: the server Deployment is recreated with a 300 s termination grace period
    helm_install INSTALL_PROMETHEUS prometheus prometheus-community/prometheus \
        "$PROMETHEUS_CHART_VERSION" prometheus.yaml 10m
    helm_install INSTALL_GRAFANA grafana grafana/grafana "$GRAFANA_CHART_VERSION" grafana.yaml 5m
    helm_install INSTALL_LOKI loki grafana/loki "$LOKI_CHART_VERSION" loki.yaml 5m
    if [[ "$INSTALL_LOKI" == "true" ]]; then
        helm_install INSTALL_PROMTAIL promtail grafana/promtail "$PROMTAIL_CHART_VERSION" promtail.yaml 3m
    fi
}

# -----------------------------------------------------------------------------
# GitOps
# -----------------------------------------------------------------------------
install_sealed_secrets() {
    if [[ "$INSTALL_SEALED_SECRETS" != "true" ]]; then
        warn "Skipping Sealed Secrets (INSTALL_SEALED_SECRETS=false)"
        return 0
    fi
    step "Installing the Sealed Secrets controller"
    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --version "$SEALED_SECRETS_CHART_VERSION" \
        --namespace kube-system \
        -f "$VPS_VALUES_DIR/sealed-secrets.yaml" \
        --wait --timeout 3m
    ok "Sealed Secrets ready: back up its key with export-secrets.sh backup-sealing-key"
}

install_argocd() {
    if [[ "$INSTALL_ARGOCD" != "true" ]]; then
        warn "Skipping Argo CD (INSTALL_ARGOCD=false)"
        return 0
    fi
    step "Installing Argo CD and Argo CD Image Updater"
    helm upgrade --install argocd argo/argo-cd \
        --version "$ARGOCD_CHART_VERSION" \
        --namespace argocd \
        -f "$VPS_VALUES_DIR/argocd.yaml" \
        --wait --timeout 5m
    helm upgrade --install argocd-image-updater argo/argocd-image-updater \
        --version "$ARGOCD_IMAGE_UPDATER_CHART_VERSION" \
        --namespace argocd \
        -f "$VPS_VALUES_DIR/argocd-image-updater.yaml" \
        --wait --timeout 3m
    bash "$SCRIPT_DIR/scripts/apply-config.sh"
}

setup_postgres_backup() {
    if [[ "$INSTALL_POSTGRESQL" != "true" ]]; then
        return 0
    fi
    step "Installing the PostgreSQL backup CronJobs"
    # Dumps made with the image of the server; off-site restic copy when
    # OFFSITE_BACKUP_REPOSITORY is set
    bash "$SCRIPT_DIR/scripts/apply-backups.sh"
}

apply_network_policies() {
    if [[ "$INSTALL_NETWORK_POLICIES" != "true" ]]; then
        warn "Skipping network policies (INSTALL_NETWORK_POLICIES=false)"
        return 0
    fi
    step "Applying network policies"
    kubectl apply -f "$VPS_MANIFESTS_DIR/network-policies.yaml"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
    local external_ip
    # IPv4: the address of the DNS A records (ifconfig.me answers in IPv6 when available)
    external_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    banner "Installation complete"
    kubectl get pods -A
    echo ""
    echo -e "${YELLOW}Next steps (vps/README.md):${NC}"
    echo -e "  1. Workstation access through an SSH tunnel:"
    echo -e "     ${BLUE}./vps/scripts/setup-remote.sh ${external_ip} --user <ssh-user>${NC}"
    echo -e "  2. Back up the Sealed Secrets key, then copy it off the server:"
    echo -e "     ${BLUE}sudo ./vps/scripts/export-secrets.sh backup-sealing-key${NC}"
    echo -e "  3. DNS: point every hostname of GATEWAY_HOSTNAMES to ${external_ip}"
    echo -e "  4. Gateway, certificates and Keycloak routes:"
    echo -e "     ${BLUE}sudo ./vps/scripts/setup-gateway-api.sh${NC}"
    echo -e "  5. Repository and registry access for every organization ($(scm_organizations)):"
    echo -e "     ${BLUE}sudo ./vps/scripts/export-secrets.sh set-scm-credentials ${SCM_PROVIDER}${NC}"
    echo -e "  6. Applications:"
    echo -e "     ${BLUE}sudo ./vps/scripts/onboard-app.sh <app-name> [--organization <org>]${NC}"
    if [[ -n "${OFFSITE_BACKUP_REPOSITORY:-}" ]]; then
        echo -e "  7. Off-site backup credentials (object storage keys, restic password):"
        echo -e "     ${BLUE}sudo ./vps/scripts/setup-secrets.sh set-offsite-backup${NC}"
    else
        echo -e "  7. Recommended: off-site backups (OFFSITE_BACKUP_REPOSITORY, vps/docs/postgres-backup.md)"
    fi
    if [[ -n "${KEYCLOAK_EXTENSION_IMAGES:-}" ]]; then
        echo -e "  8. Private Keycloak extension images: Keycloak pulls them once step 5 is done:"
        echo -e "     ${BLUE}sudo ./vps/scripts/apply-keycloak.sh${NC}"
    fi
    echo ""
    echo -e "Credentials: ${BLUE}sudo ./vps/scripts/export-secrets.sh show${NC}"
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) usage; die "unknown argument: $1" ;;
    esac

    banner "k3s-stack - VPS installation"
    require_root
    check_system
    bash "$SCRIPT_DIR/scripts/apply-config.sh" --check
    load_config
    use_k3s_kubeconfig

    install_dependencies
    install_k3s
    harden_host
    install_helm
    setup_helm_repos
    create_namespaces
    setup_secrets
    install_gateway_api
    install_cert_manager
    install_postgresql
    create_keycloak_database
    install_keycloak
    install_redis
    install_observability
    install_sealed_secrets
    install_argocd
    setup_postgres_backup
    apply_network_policies
    print_summary
}

main "$@"
