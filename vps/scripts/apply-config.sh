#!/bin/bash
set -euo pipefail

# =============================================================================
# Validates vps/config.env and applies the GitOps configuration rendered from it:
#   - Argo CD ApplicationSets   templates/argocd/applicationsets.yaml.tpl, one
#                               scmProvider generator per organization of
#                               SCM_ORGANIZATIONS (templates/argocd/generator-*.yaml.tpl)
#   - Image Updater CRs         manifests/argocd-image-updaters.yaml
# Called by install.sh (--check first, then apply); run it again after changing
# SCM_ORGANIZATIONS, REGISTRY_HOST or REGISTRY_BASE.
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
        "(one generator per organization of SCM_ORGANIZATIONS) and Image Updater CRs" \
        "(root required to apply)." \
        "" \
        "  --check    validate config.env only" \
        "  --dry-run  print the rendered manifests without applying them"
}

validate_config() {
    load_config
    require_config SCM_PROVIDER LETSENCRYPT_EMAIL
    validate_scm_config
    echo "$LETSENCRYPT_EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' \
        || die "LETSENCRYPT_EMAIL is not a valid email: $LETSENCRYPT_EMAIL"
    validate_gateway_config
    validate_keycloak_config
    validate_offsite_config
    ok "config.env is valid (organizations: $(scm_organizations))"
}

# render_applicationsets: ApplicationSets with one generator per organization
render_applicationsets() {
    local org image alpha="" prod=""
    for org in $(scm_organizations); do
        image=$(image_base "$org")
        alpha="$alpha$(render_template "$VPS_TEMPLATES_DIR/argocd/generator-alpha.yaml.tpl" \
            "ORGANIZATION=$org" "IMAGE_BASE=$image")"$'\n'
        prod="$prod$(render_template "$VPS_TEMPLATES_DIR/argocd/generator-prod.yaml.tpl" \
            "ORGANIZATION=$org" "IMAGE_BASE=$image")"$'\n'
    done
    render_template "$VPS_TEMPLATES_DIR/argocd/applicationsets.yaml.tpl" \
        "ALPHA_GENERATORS=$alpha" "PROD_GENERATORS=$prod"
}

render_gitops() {
    render_applicationsets
    cat "$VPS_MANIFESTS_DIR/argocd-image-updaters.yaml"
}

apply_gitops() {
    require_root
    use_k3s_kubeconfig
    kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1 \
        || die "Argo CD is not installed (vps/install.sh)"
    step "Applying the Argo CD auto-discovery ($(scm_organizations))"
    render_applicationsets | kubectl apply -f -
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
