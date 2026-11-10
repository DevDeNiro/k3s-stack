#!/bin/bash
set -euo pipefail

# =============================================================================
# Validates vps/config.env and applies the GitOps configuration rendered from it:
#   - Argo CD ApplicationSets   templates/argocd/applicationsets.yaml.tpl
#   - Image Updater CRs         manifests/argocd-image-updaters.yaml
# Called by install.sh; run it again after changing SCM_ORGANIZATION or REGISTRY_BASE.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE="apply"

usage() {
    printf '%s\n' \
        "Usage: [sudo] $0 [--check | --dry-run]" \
        "" \
        "Validates vps/config.env, then renders and applies the Argo CD ApplicationSets" \
        "and Image Updater CRs (root required to apply)." \
        "" \
        "  --check    validate config.env only" \
        "  --dry-run  print the rendered manifests without applying them"
}

validate_config() {
    load_config
    require_config SCM_PROVIDER SCM_ORGANIZATION REGISTRY_BASE LETSENCRYPT_EMAIL
    case "$SCM_PROVIDER" in
        github|gitlab) ;;
        *) die "SCM_PROVIDER must be github or gitlab (got: $SCM_PROVIDER)" ;;
    esac
    echo "$LETSENCRYPT_EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' \
        || die "LETSENCRYPT_EMAIL is not a valid email: $LETSENCRYPT_EMAIL"
    validate_gateway_config
    ok "config.env is valid"
}

render_gitops() {
    render_template "$VPS_TEMPLATES_DIR/argocd/applicationsets.yaml.tpl" SCM_ORGANIZATION REGISTRY_BASE
    cat "$VPS_MANIFESTS_DIR/argocd-image-updaters.yaml"
}

apply_gitops() {
    require_root
    use_k3s_kubeconfig
    kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1 \
        || die "Argo CD is not installed (vps/install.sh)"
    step "Applying the Argo CD auto-discovery"
    render_template "$VPS_TEMPLATES_DIR/argocd/applicationsets.yaml.tpl" SCM_ORGANIZATION REGISTRY_BASE \
        | kubectl apply -f -
    kubectl apply -f "$VPS_MANIFESTS_DIR/argocd-image-updaters.yaml"
    ok "ApplicationSets and Image Updater CRs applied"
    kubectl get secret scm-token -n argocd >/dev/null 2>&1 \
        || warn "Repository access missing: sudo ./vps/scripts/export-secrets.sh set-scm-credentials $SCM_PROVIDER"
}

main() {
    case "${1:-}" in
        --check) MODE="check" ;;
        --dry-run) MODE="dry-run" ;;
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) usage; die "unknown option: $1" ;;
    esac

    validate_config
    case "$MODE" in
        check) ;;
        dry-run) render_gitops ;;
        apply) apply_gitops ;;
    esac
}

main "$@"
