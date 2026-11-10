#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s maintenance on the VPS: status, datastore backup and restore, upgrades.
#
# The K3s flags live in /etc/rancher/k3s/config.yaml (installed by install.sh)
# and the K3s installer always runs without arguments, so upgrades keep them.
# Designed for the single-server SQLite datastore created by install.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

K3S_SERVER_DIR="/var/lib/rancher/k3s/server"
K3S_CONFIG_FILE="/etc/rancher/k3s/config.yaml"
K3S_BACKUP_DIR="$BACKUP_DIR/k3s"
K3S_CHANNELS_URL="https://update.k3s.io/v1-release/channels"
KEEP_BACKUPS=5
TARGET_VERSION=""

usage() {
    printf '%s\n' \
        "Usage: sudo $0 <command> [options]" \
        "" \
        "Commands:" \
        "  status                 installed and available versions, configuration, secrets encryption" \
        "  backup                 cold backup of the datastore and its keys into $K3S_BACKUP_DIR" \
        "                         (K3s stopped ~10 s, workloads keep running; last $KEEP_BACKUPS kept)" \
        "  upgrade [--version V]  backup, then upgrade to the latest patch of the next minor" \
        "                         (or of the current minor when it is the latest stable one)." \
        "                         --version: explicit release (same or next minor only)" \
        "  restore <archive>      restore a backup of this script, with its K3s version" \
        "" \
        "Options:" \
        "  --yes, -y              no confirmation prompt"
}

current_version() {
    k3s --version | awk 'NR == 1 {print $3}'
}

# Gateway API CRDs bundled with K3s (gateway-api-crd component)
gateway_api_version() {
    kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null
}

# channel_latest <channel>: latest release of a K3s channel (stable, v1.37...)
channel_latest() {
    curl -fsSL --max-time 15 "$K3S_CHANNELS_URL" \
        | jq -r --arg channel "$1" '.data[] | select(.name == $channel) | .latest'
}

# Flags passed to the installer end up in the systemd unit and are lost at the next upgrade
service_flags() {
    systemctl show k3s --property=ExecStart --value 2>/dev/null \
        | sed -nE 's/.*argv\[\]=[^ ]+ server ?([^;]*);.*/\1/p' | xargs
}

wait_node_ready() {
    for _ in $(seq 1 60); do
        kubectl get nodes >/dev/null 2>&1 && break
        sleep 5
    done
    kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
}

check_upgradable() {
    [[ -f "$K3S_CONFIG_FILE" ]] \
        || die "$K3S_CONFIG_FILE is missing: the installer would drop the K3s flags. Reinstall with vps/install.sh."
    [[ -z "$(service_flags)" ]] \
        || die "K3s flags are passed to the service ($(service_flags)): they would be lost. Reinstall with vps/install.sh."
    [[ ! -d "$K3S_SERVER_DIR/db/etcd" ]] \
        || die "embedded etcd datastore: this script handles the SQLite datastore of install.sh only"
}

cmd_status() {
    local version stable
    version=$(current_version)
    stable=$(channel_latest stable 2>/dev/null || true)

    banner "K3s status"
    echo "Installed version  : $version"
    echo "Latest stable      : ${stable:-unknown (offline?)}"
    echo "Gateway API CRDs   : $(gateway_api_version) (shipped with K3s)"
    if [[ -f "$K3S_CONFIG_FILE" ]]; then
        echo "Configuration file : $K3S_CONFIG_FILE"
    else
        echo -e "Configuration file : ${RED}missing (flags would be lost at upgrade)${NC}"
    fi
    if [[ -n "$(service_flags)" ]]; then
        echo -e "Service flags      : ${RED}$(service_flags) (lost at upgrade: reinstall)${NC}"
    fi
    echo ""
    k3s secrets-encrypt status 2>/dev/null | head -3 || warn "secrets-encrypt status unavailable"
    echo ""
    kubectl get nodes -o wide
    echo ""
    echo "Backups in $K3S_BACKUP_DIR:"
    ls -1t "$K3S_BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "  none"
}

cmd_backup() {
    local version archive
    [[ ! -d "$K3S_SERVER_DIR/db/etcd" ]] \
        || die "embedded etcd datastore: use 'k3s etcd-snapshot save' instead"
    version=$(current_version)
    archive="$K3S_BACKUP_DIR/k3s-${version}-$(date -u +%Y%m%d-%H%M%S).tar.gz"

    step "Backing up the K3s datastore (${version})"
    install -d -m 700 "$K3S_BACKUP_DIR"
    # Stopping the server leaves the containers running (KillMode=process)
    systemctl stop k3s
    trap 'systemctl start k3s' EXIT
    tar -czf "$archive" -C / \
        "${K3S_SERVER_DIR#/}/db" "${K3S_SERVER_DIR#/}/token" "${K3S_SERVER_DIR#/}/cred" \
        "${K3S_SERVER_DIR#/}/tls" etc/rancher/k3s
    chmod 600 "$archive"
    systemctl start k3s
    trap - EXIT
    wait_node_ready

    # Rotation: the KEEP_BACKUPS most recent archives are kept
    find "$K3S_BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' \
        | sort -rn | tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2- | xargs -r -d '\n' rm -f
    ok "Backup: $archive"
}

cmd_upgrade() {
    local current current_minor stable target
    check_upgradable
    current=$(current_version)
    current_minor=$(k3s_minor "$current")

    if [[ -n "$TARGET_VERSION" ]]; then
        target="$TARGET_VERSION"
        local target_minor
        target_minor=$(k3s_minor "$target")
        [[ "$target_minor" == "$current_minor" || "$target_minor" == "$((current_minor + 1))" ]] \
            || die "upgrade one minor at a time: $current -> v1.$((current_minor + 1)).x first"
    else
        stable=$(channel_latest stable)
        [[ -n "$stable" ]] || die "cannot read the K3s release channels ($K3S_CHANNELS_URL)"
        if [[ "$(k3s_minor "$stable")" -gt "$current_minor" ]]; then
            target=$(channel_latest "v1.$((current_minor + 1))")
        else
            target=$(channel_latest "v1.${current_minor}")
        fi
    fi
    [[ -n "$target" ]] || die "no release found for the upgrade of $current"
    if [[ "$target" == "$current" ]]; then
        ok "K3s $current is already the latest release of its channel"
        return 0
    fi

    confirm "Upgrade K3s $current -> $target (backup first)?" || die "aborted"
    cmd_backup

    step "Upgrading K3s to $target"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$target" sh -
    wait_node_ready
    [[ "$(current_version)" == "$target" ]] || die "K3s reports $(current_version) instead of $target"

    if kubectl get deployment traefik -n kube-system >/dev/null 2>&1 \
        || [[ -n "$(kubectl get daemonsets -A -l svccontroller.k3s.cattle.io/svcname -o name 2>/dev/null)" ]]; then
        die "traefik or servicelb came back: check $K3S_CONFIG_FILE"
    fi
    if [[ "$(k3s_minor "$target")" -ge 37 ]]; then
        wait_gateway_api_crds
        echo "A new Gateway API release may need a newer NGINX Gateway Fabric (config/versions.env)."
    fi
    kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
    ok "K3s $target running. Run '$0 upgrade' again for the next minor."
}

cmd_restore() {
    local archive="$1" version aside
    [[ -f "$archive" ]] || die "archive not found: $archive"
    version=$(basename "$archive" | sed -nE 's/^k3s-(v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+)-[0-9]{8}-[0-9]{6}\.tar\.gz$/\1/p')
    [[ -n "$version" ]] || die "not a backup of this script: $archive"
    aside="${K3S_SERVER_DIR}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"

    confirm "Restore K3s $version from $(basename "$archive")? The current state moves to $aside" || die "aborted"

    step "Restoring the K3s datastore ($version)"
    systemctl stop k3s
    install -d -m 700 "$aside"
    mv "$K3S_SERVER_DIR/db" "$K3S_SERVER_DIR/token" "$K3S_SERVER_DIR/cred" "$K3S_SERVER_DIR/tls" "$aside"/
    cp -a /etc/rancher/k3s "$aside/etc-rancher-k3s"
    tar -xzf "$archive" -C /

    if [[ "$(current_version)" == "$version" ]]; then
        systemctl start k3s
    else
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$version" sh -
    fi
    wait_node_ready
    ok "K3s $version restored; previous state kept in $aside"
}

main() {
    local command="${1:-}" archive=""
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                [[ "${2:-}" =~ ^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die "--version expects vX.Y.Z+k3sN"
                TARGET_VERSION="$2"
                shift
                ;;
            --yes|-y) ASSUME_YES=true ;;
            -h|--help) usage; exit 0 ;;
            -*) usage; die "unknown option: $1" ;;
            *) archive="$1" ;;
        esac
        shift
    done

    case "$command" in
        status|backup|upgrade|restore) ;;
        -h|--help|help|"") usage; exit 0 ;;
        *) usage; die "unknown command: $command" ;;
    esac

    require_root
    require_commands k3s kubectl curl jq
    use_k3s_kubeconfig

    case "$command" in
        status) cmd_status ;;
        backup) cmd_backup ;;
        upgrade) cmd_upgrade ;;
        restore)
            [[ -n "$archive" ]] || die "restore requires an archive (see: $0 status)"
            cmd_restore "$archive"
            ;;
    esac
}

main "$@"
