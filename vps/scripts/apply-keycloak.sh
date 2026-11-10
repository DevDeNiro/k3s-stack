#!/bin/bash
set -euo pipefail

# =============================================================================
# Keycloak (namespace security), rendered from templates/keycloak/ with the
# extension images of KEYCLOAK_EXTENSION_IMAGES (vps/config.env). Each image
# provides themes (/themes/<name>/) and/or provider JARs (/providers/*.jar); an
# initContainer copies them into /opt/keycloak/themes and /opt/keycloak/providers
# at every start. Keycloak starts without --optimized: it rebuilds itself when
# the providers change.
# Called by install.sh (--no-restart); run it again after changing the images:
# the restart makes Keycloak copy them again (logins unavailable ~1-2 minutes).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
RESTART=true
ROLLOUT_TIMEOUT="600s"

usage() {
    printf '%s\n' \
        "Usage: sudo $0 [--dry-run] [--no-restart]" \
        "" \
        "Renders Keycloak with the extension images of KEYCLOAK_EXTENSION_IMAGES (vps/config.env)," \
        "applies it and restarts Keycloak, then waits for it to be ready." \
        "" \
        "  --dry-run     print the rendered manifest without applying it (no root needed)" \
        "  --no-restart  apply only: Keycloak restarts only when the manifest changed"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --no-restart) RESTART=false ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

# statefulset_generation: generation of the Keycloak StatefulSet, empty when missing
statefulset_generation() {
    kubectl get statefulset keycloak -n security -o jsonpath='{.metadata.generation}' 2>/dev/null || true
}

main() {
    parse_args "$@"
    if [[ "$DRY_RUN" != "true" ]]; then
        require_root
    fi
    load_config
    validate_keycloak_config
    local images="${KEYCLOAK_EXTENSION_IMAGES:-}" before after

    if [[ "$DRY_RUN" == "true" ]]; then
        # shellcheck disable=SC2086  # word splitting of the image list
        render_keycloak_manifest $images
        return 0
    fi

    use_k3s_kubeconfig
    kubectl get secret keycloak-db-secret -n security >/dev/null 2>&1 \
        || die "Secret security/keycloak-db-secret not found: Keycloak is installed by vps/install.sh"

    step "Keycloak (extension images: ${images:-none})"
    before=$(statefulset_generation)
    # shellcheck disable=SC2086  # word splitting of the image list
    render_keycloak_manifest $images | kubectl apply -f -
    after=$(statefulset_generation)
    if [[ -n "$before" && "$before" == "$after" && "$RESTART" == "true" ]]; then
        # Unchanged manifest: restart so that the initContainers copy the extensions again
        kubectl rollout restart statefulset/keycloak -n security
    fi

    if [[ -n "$images" ]] && ! kubectl get secret "$KEYCLOAK_PULL_SECRET" -n security >/dev/null 2>&1; then
        warn "No Secret security/$KEYCLOAK_PULL_SECRET: private extension images cannot be pulled."
        echo "  Run: sudo ./vps/scripts/export-secrets.sh set-scm-credentials github, then this script again."
        return 0
    fi
    kubectl rollout status statefulset/keycloak -n security --timeout="$ROLLOUT_TIMEOUT" \
        || warn "Keycloak is still starting: kubectl get pods -n security; kubectl describe pod keycloak-0 -n security"
}

main "$@"
