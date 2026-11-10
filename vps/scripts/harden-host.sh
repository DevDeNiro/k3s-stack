#!/bin/bash
set -euo pipefail

# =============================================================================
# Host hardening of the k3s-stack VPS: UFW firewall, optional SSH hardening and
# automatic security updates. Dry run by default, --apply executes.
#
# Firewall policy (UFW):
#   - incoming traffic denied by default, outgoing allowed
#   - SSH (configured port, rate limited), HTTP 80 and HTTPS 443
#   - K3s pod and service networks, needed by the cluster itself, and the
#     traffic forwarded to and from the pods (UFW denies routed traffic by default)
#   - Kubernetes API (6443/tcp) only from --allow-api-from networks: none by
#     default, kubectl goes through an SSH tunnel (scripts/setup-remote.sh)
# UFW does not filter traffic forwarded to hostPorts or NodePorts: expose
# nothing but the Gateway hostPorts (80/443).
# Configuration files: vps/config/ssh/, vps/config/apt/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APPLY=false
HARDEN_SSH=false
AUTO_UPDATES=false
SSH_PORTS=""
API_CIDRS=()

K3S_CONFIG_FILE="/etc/rancher/k3s/config.yaml"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-k3s-stack-hardening.conf"
APT_PERIODIC="/etc/apt/apt.conf.d/20auto-upgrades"

usage() {
    printf '%s\n' \
        "Usage: sudo $0 [--apply] [--yes] [--allow-api-from CIDR]... [--ssh-port PORT]..." \
        "                 [--harden-ssh] [--auto-updates]" \
        "" \
        "Dry run by default: prints the actions without changing anything." \
        "" \
        "  --apply                apply the changes" \
        "  --yes, -y              no confirmation prompt (with --apply)" \
        "  --allow-api-from CIDR  allow the Kubernetes API (6443/tcp) from CIDR, repeatable" \
        "                         (default: no network, use an SSH tunnel)" \
        "  --ssh-port PORT        SSH port to allow, repeatable (default: detected with sshd -T)" \
        "  --harden-ssh           key-only SSH logins, no root password login" \
        "                         (refused when no authorized key exists for root or the sudo user)" \
        "  --auto-updates         unattended security updates, no automatic reboot"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply) APPLY=true ;;
            --dry-run) APPLY=false ;;
            --yes|-y) ASSUME_YES=true ;;
            --allow-api-from)
                [[ -n "${2:-}" ]] || die "--allow-api-from requires a CIDR"
                API_CIDRS+=("$2")
                shift
                ;;
            --ssh-port)
                [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--ssh-port requires a port number"
                SSH_PORTS="$SSH_PORTS $2"
                shift
                ;;
            --harden-ssh) HARDEN_SSH=true ;;
            --auto-updates) AUTO_UPDATES=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

# run <command...>: executes with --apply, prints otherwise
run() {
    if [[ "$APPLY" == "true" ]]; then
        "$@"
    else
        echo "  [dry-run] $*"
    fi
}

# detect_ssh_ports: ports of the effective sshd configuration, 22 when unknown
detect_ssh_ports() {
    if [[ -z "$SSH_PORTS" ]] && command -v sshd >/dev/null 2>&1; then
        SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | xargs) || SSH_PORTS=""
    fi
    SSH_PORTS=$(echo "${SSH_PORTS:-22}" | xargs)
}

# k3s_cidr <key> <default>: value from the K3s configuration file, or default
k3s_cidr() {
    local value=""
    if [[ -f "$K3S_CONFIG_FILE" ]]; then
        value=$(awk -F': *' -v key="$1" '$1 == key {gsub(/"/, "", $2); print $2; exit}' "$K3S_CONFIG_FILE")
    fi
    echo "${value:-$2}"
}

configure_firewall() {
    local cluster_cidr service_cidr port cidr number
    cluster_cidr=$(k3s_cidr cluster-cidr 10.42.0.0/16)
    service_cidr=$(k3s_cidr service-cidr 10.43.0.0/16)

    step "Firewall (UFW)"
    if ! command -v ufw >/dev/null 2>&1; then
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
    fi

    run ufw default deny incoming
    run ufw default allow outgoing
    for port in $SSH_PORTS; do
        # "limit" instead of a plain "allow" rule that would take precedence
        run ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
        run ufw limit "$port/tcp" comment 'SSH'
    done
    run ufw allow 80/tcp comment 'HTTP (Gateway)'
    run ufw allow 443/tcp comment 'HTTPS (Gateway)'
    run ufw allow from "$cluster_cidr" comment 'K3s pods'
    run ufw allow from "$service_cidr" comment 'K3s services'
    # Pod traffic crossing the node (bridge, egress, hostPorts): accepted even when
    # the CNI rules live in another iptables backend than the UFW chains
    run ufw route allow from "$cluster_cidr" comment 'K3s pods (forwarded)'
    run ufw route allow to "$cluster_cidr" comment 'K3s pods (forwarded)'

    # Kubernetes API: every existing rule is removed, then only the allowed networks are added
    if command -v ufw >/dev/null 2>&1; then
        for number in $(ufw status numbered 2>/dev/null \
            | grep -E '(^|[^0-9])6443([^0-9]|$)' \
            | sed -nE 's/^\[ *([0-9]+)\].*/\1/p' | sort -rn); do
            run ufw --force delete "$number"
        done
    fi
    for cidr in "${API_CIDRS[@]+"${API_CIDRS[@]}"}"; do
        run ufw allow from "$cidr" to any port 6443 proto tcp comment 'Kubernetes API'
    done

    run ufw --force enable
    if [[ "$APPLY" == "true" ]]; then
        ufw status verbose
    fi
}

harden_ssh() {
    step "SSH hardening"
    local users=(root) user home found=false
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        users+=("$SUDO_USER")
    fi
    for user in "${users[@]}"; do
        home=$(getent passwd "$user" | cut -d: -f6)
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            found=true
        fi
    done
    [[ "$found" == "true" ]] || die "no authorized SSH key for ${users[*]}: disabling password logins would lock you out"
    grep -Eqs '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config \
        || warn "/etc/ssh/sshd_config does not include sshd_config.d: $SSHD_DROPIN would be ignored"

    run install -m 644 "$VPS_CONFIG_DIR/ssh/10-k3s-stack-hardening.conf" "$SSHD_DROPIN"
    if [[ "$APPLY" == "true" ]]; then
        if ! sshd -t; then
            rm -f "$SSHD_DROPIN"
            die "sshd rejected the configuration: $SSHD_DROPIN removed"
        fi
        # Socket-activated sshd (Ubuntu 24.04+) reads the configuration at each connection
        if systemctl is-active --quiet ssh; then
            systemctl reload ssh
        elif systemctl is-active --quiet sshd; then
            systemctl reload sshd
        fi
        ok "Key-only SSH logins: test a new session before closing this one"
    fi
}

enable_auto_updates() {
    step "Automatic security updates"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
    run install -m 644 "$VPS_CONFIG_DIR/apt/20auto-upgrades" "$APT_PERIODIC"
    run systemctl enable --now unattended-upgrades
}

main() {
    parse_args "$@"
    require_root
    command -v apt-get >/dev/null 2>&1 || die "an apt-based distribution is required (Ubuntu, Debian)"
    detect_ssh_ports

    banner "Host hardening ($([[ "$APPLY" == "true" ]] && echo "apply" || echo "dry run"))"
    echo "SSH port(s)             : $SSH_PORTS"
    echo "Kubernetes API allowed  : ${API_CIDRS[*]:-nobody (SSH tunnel)}"
    echo "SSH hardening           : $HARDEN_SSH"
    echo "Automatic updates       : $AUTO_UPDATES"

    if [[ "$APPLY" == "true" ]]; then
        confirm "Apply? Keep a second SSH session open until a new login is confirmed." || die "aborted"
    fi

    configure_firewall
    if [[ "$HARDEN_SSH" == "true" ]]; then
        harden_ssh
    fi
    if [[ "$AUTO_UPDATES" == "true" ]]; then
        enable_auto_updates
    fi

    if [[ "$APPLY" == "true" ]]; then
        ok "Host hardened"
    else
        echo -e "\n${YELLOW}Dry run: nothing changed. Re-run with --apply.${NC}"
    fi
}

main "$@"
