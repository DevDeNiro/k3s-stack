#!/bin/bash
set -euo pipefail

# =============================================================================
# Infrastructure credentials: generated once into /root/.k3s-secrets/credentials.env
# (template: templates/secrets/credentials.env.tpl) and pushed as Kubernetes Secrets.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SECRETS_FILE="$SECRETS_DIR/credentials.env"
CREDENTIAL_VARS=(
    POSTGRES_ADMIN_PASSWORD
    KEYCLOAK_ADMIN_PASSWORD
    KEYCLOAK_DB_PASSWORD
    GRAFANA_ADMIN_PASSWORD
    ARGOCD_ADMIN_PASSWORD
)

usage() {
    printf '%s\n' \
        "Usage: sudo $0 <command>" \
        "" \
        "Commands:" \
        "  setup                generate the infrastructure passwords (first run only) and" \
        "                       create the Kubernetes Secrets; existing credentials are reused" \
        "  rotate               regenerate the PostgreSQL superuser, Keycloak database and Argo CD" \
        "                       admin passwords, then restart PostgreSQL and Keycloak" \
        "  set-discord-webhook  create or update the Alertmanager Discord webhook Secret" \
        "                       (monitoring/alertmanager-discord-webhook, hidden input)" \
        "" \
        "The Keycloak and Grafana admin passwords only apply at their first start:" \
        "change them in their consoles afterwards." \
        "Credentials: ${SECRETS_FILE} (display: export-secrets.sh show)"
}

generate_credentials() {
    POSTGRES_ADMIN_PASSWORD=$(generate_password 32)
    KEYCLOAK_ADMIN_PASSWORD=$(generate_password 24)
    KEYCLOAK_DB_PASSWORD=$(generate_password 32)
    GRAFANA_ADMIN_PASSWORD=$(generate_password 24)
    ARGOCD_ADMIN_PASSWORD=$(generate_password 24)
}

load_credentials() {
    # shellcheck source=/dev/null
    . "$SECRETS_FILE"
    require_config "${CREDENTIAL_VARS[@]}"
}

save_credentials() {
    install -d -m 700 "$SECRETS_DIR"
    (
        umask 077
        render_template "$VPS_TEMPLATES_DIR/secrets/credentials.env.tpl" \
            "GENERATED_AT=$(date -Iseconds)" "${CREDENTIAL_VARS[@]}" > "$SECRETS_FILE.tmp"
    )
    mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"
}

# bcrypt hash expected by Argo CD ($2a$ prefix), password read on stdin
argocd_password_hash() {
    # shellcheck disable=SC2016  # literal bcrypt prefixes, not expansions
    printf '%s' "$ARGOCD_ADMIN_PASSWORD" | htpasswd -niBC 10 "" | tr -d ':\n' | sed 's/^\$2y/$2a/'
}

apply_infrastructure_secrets() {
    step "Kubernetes Secrets"
    apply_secret storage postgresql-secret "postgres-password=$POSTGRES_ADMIN_PASSWORD"
    apply_secret security keycloak-secret "admin-password=$KEYCLOAK_ADMIN_PASSWORD"
    apply_secret security keycloak-db-secret "password=$KEYCLOAK_DB_PASSWORD"
    apply_secret monitoring grafana-secret admin-user=admin "admin-password=$GRAFANA_ADMIN_PASSWORD"
    require_commands htpasswd
    apply_secret argocd argocd-secret "admin.password=$(argocd_password_hash)" \
        "admin.passwordMtime=$(date -u +%FT%TZ)"
    ok "postgresql-secret, keycloak-secret, keycloak-db-secret, grafana-secret, argocd-secret"
}

cmd_setup() {
    banner "Infrastructure credentials"
    if [[ -s "$SECRETS_FILE" ]]; then
        load_credentials
        ok "Existing credentials reused: $SECRETS_FILE"
    else
        generate_credentials
        save_credentials
        ok "Credentials generated: $SECRETS_FILE"
    fi
    apply_infrastructure_secrets
}

cmd_rotate() {
    [[ -s "$SECRETS_FILE" ]] || die "no credentials to rotate: $SECRETS_FILE"
    confirm "Regenerate the PostgreSQL, Keycloak database and Argo CD passwords (restarts PostgreSQL and Keycloak)?" \
        || die "aborted"
    load_credentials
    local current_admin_password="$POSTGRES_ADMIN_PASSWORD"
    POSTGRES_ADMIN_PASSWORD=$(generate_password 32)
    KEYCLOAK_DB_PASSWORD=$(generate_password 32)
    ARGOCD_ADMIN_PASSWORD=$(generate_password 24)

    step "Updating the PostgreSQL roles"
    pg_wait_ready 120s
    pg_exec postgres postgres "$current_admin_password" "$VPS_SQL_DIR/rotate-passwords.sql" \
        "postgres_password=$POSTGRES_ADMIN_PASSWORD" "keycloak_password=$KEYCLOAK_DB_PASSWORD"
    save_credentials
    apply_infrastructure_secrets

    step "Restarting PostgreSQL and Keycloak"
    kubectl rollout restart statefulset/postgresql -n storage
    kubectl rollout restart statefulset/keycloak -n security 2>/dev/null || true
    kubectl rollout status statefulset/postgresql -n storage --timeout=180s
    ok "Passwords rotated (display: sudo ./vps/scripts/export-secrets.sh show)"
}

cmd_set_discord_webhook() {
    local webhook_url
    banner "Alertmanager Discord webhook"
    echo "Discord: Server Settings > Integrations > Webhooks > New Webhook, then Copy Webhook URL"
    echo "(https://discord.com/api/webhooks/<ID>/<TOKEN>). Alertmanager uses its native Discord integration."
    read -r -s -p "Webhook URL: " webhook_url
    echo ""
    [[ -n "$webhook_url" ]] || die "the URL cannot be empty"
    [[ "$webhook_url" =~ ^https://discord(app)?\.com/api/webhooks/ ]] \
        || confirm "This does not look like a Discord webhook. Continue?" || die "aborted"
    # The Slack-compatible endpoint is not used
    webhook_url="${webhook_url%/}"
    webhook_url="${webhook_url%/slack}"

    apply_secret monitoring alertmanager-discord-webhook "webhook-url=$webhook_url"
    ok "Secret monitoring/alertmanager-discord-webhook updated"
    echo "Reload Alertmanager: kubectl rollout restart statefulset/prometheus-alertmanager -n monitoring"
    echo "Test: kubectl exec -n monitoring prometheus-alertmanager-0 -c alertmanager -- \\"
    echo "        amtool --alertmanager.url=http://localhost:9093 alert add k3s-stack-test severity=warning"
}

main() {
    local command="${1:-}"
    case "$command" in
        setup|rotate|set-discord-webhook) ;;
        -h|--help|help|"") usage; exit 0 ;;
        *) usage; die "unknown command: $command" ;;
    esac
    require_root
    use_k3s_kubeconfig

    case "$command" in
        setup) cmd_setup ;;
        rotate) cmd_rotate ;;
        set-discord-webhook) cmd_set_discord_webhook ;;
    esac
}

main "$@"
