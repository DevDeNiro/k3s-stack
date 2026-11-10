#!/bin/bash
set -euo pipefail

# =============================================================================
# Workstation access to the VPS cluster (macOS or Linux, bash 3.2+).
# The Kubernetes API is closed to the Internet (harden-host.sh): kubectl goes
# through an SSH tunnel to 127.0.0.1:6443 on the VPS, which the K3s API
# certificate already covers. Fetches the admin kubeconfig, points it at the
# tunnel (or at the VPS with --direct) and renames its context.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

VPS_HOST=""
SSH_USER="root"
SSH_PORT="22"
LOCAL_PORT="16443"
CONTEXT="k3s-vps"
DIRECT=false

usage() {
    printf '%s\n' \
        "Usage: $0 <vps-host> [--user USER] [--port SSH_PORT] [--local-port PORT]" \
        "                       [--context NAME] [--direct]" \
        "" \
        "Writes ~/.kube/config-<context> for the VPS cluster and checks the access." \
        "" \
        "  --user USER        SSH user with passwordless sudo (default: root)" \
        "  --port SSH_PORT    SSH port (default: 22)" \
        "  --local-port PORT  local end of the SSH tunnel (default: 16443)" \
        "  --context NAME     kubeconfig context, cluster and user name (default: k3s-vps)" \
        "  --direct           https://<vps-host>:6443 without tunnel: requires" \
        "                     harden-host.sh --allow-api-from <your-ip>/32 on the VPS"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) SSH_USER="${2:?--user requires a value}"; shift ;;
            --port) SSH_PORT="${2:?--port requires a value}"; shift ;;
            --local-port) LOCAL_PORT="${2:?--local-port requires a value}"; shift ;;
            --context) CONTEXT="${2:?--context requires a value}"; shift ;;
            --direct) DIRECT=true ;;
            -h|--help) usage; exit 0 ;;
            -*) usage; die "unknown option: $1" ;;
            *)
                [[ -z "$VPS_HOST" ]] || die "only one VPS host"
                VPS_HOST="$1"
                ;;
        esac
        shift
    done
    [[ -n "$VPS_HOST" ]] || { usage; exit 1; }
    KUBECONFIG_FILE="$HOME/.kube/config-${CONTEXT}"
}

ssh_vps() {
    ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${VPS_HOST}" "$@"
}

fetch_kubeconfig() {
    local server raw
    step "Fetching the kubeconfig from ${SSH_USER}@${VPS_HOST}"
    raw=$(ssh_vps 'sudo -n cat /etc/rancher/k3s/k3s.yaml') \
        || die "cannot read /etc/rancher/k3s/k3s.yaml (SSH key and passwordless sudo required for ${SSH_USER})"
    if [[ "$DIRECT" == "true" ]]; then
        server="https://${VPS_HOST}:6443"
    else
        server="https://127.0.0.1:${LOCAL_PORT}"
    fi

    mkdir -p "$HOME/.kube"
    (
        umask 077
        printf '%s\n' "$raw" | sed -E \
            -e "s#^([[:space:]]*server:).*#\\1 ${server}#" \
            -e "s/^([[:space:]]*(- )?(name|cluster|user|current-context)): default$/\\1: ${CONTEXT}/" \
            > "$KUBECONFIG_FILE"
    )
    ok "Kubeconfig: $KUBECONFIG_FILE (server $server, context $CONTEXT)"
}

check_access() {
    local socket="" status=0
    step "Checking the access to the cluster"
    if [[ "$DIRECT" != "true" ]] && ! nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
        socket="$(mktemp -u "${TMPDIR:-/tmp}/k3s-tunnel.XXXXXX")"
        ssh -f -N -M -S "$socket" -o ExitOnForwardFailure=yes -p "$SSH_PORT" \
            -L "${LOCAL_PORT}:127.0.0.1:6443" "${SSH_USER}@${VPS_HOST}"
    fi
    kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes || status=$?
    if [[ -n "$socket" ]]; then
        ssh -S "$socket" -O exit -p "$SSH_PORT" "${SSH_USER}@${VPS_HOST}" >/dev/null 2>&1 || true
    fi
    [[ $status -eq 0 ]] || die "the cluster is not reachable"
}

print_instructions() {
    banner "Workstation access ready"
    if [[ "$DIRECT" != "true" ]]; then
        echo "1. Open the tunnel (background):"
        echo "     ssh -fN -L ${LOCAL_PORT}:127.0.0.1:6443 -p ${SSH_PORT} ${SSH_USER}@${VPS_HOST}"
        echo "   or add a LocalForward to ~/.ssh/config (vps/docs/workstation-setup.md)."
        echo "2. Use the cluster:"
    fi
    echo "     export KUBECONFIG=${KUBECONFIG_FILE}"
    echo "     kubectl get pods -A"
}

main() {
    parse_args "$@"
    require_commands ssh kubectl sed
    if [[ "$DIRECT" != "true" ]]; then
        require_commands nc
    fi
    fetch_kubeconfig
    check_access
    print_instructions
}

main "$@"
