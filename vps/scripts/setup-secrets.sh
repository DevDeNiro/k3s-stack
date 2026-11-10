#!/bin/bash
set -euo pipefail

# =============================================================================
# Infrastructure credentials: generated once into /root/.k3s-secrets/credentials.env
# (template: templates/secrets/credentials.env.tpl) and pushed as Kubernetes Secrets.
# Credentials typed by the operator (Discord webhook, off-site backup keys) are
# read without echo, never from command arguments.
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
# Off-site backup credentials (templates/secrets/offsite-backup.env.tpl)
OFFSITE_SECRETS_FILE="$SECRETS_DIR/offsite-backup.env"

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
        "  set-offsite-backup   create or update the credentials of the off-site backup copy" \
        "                       (storage/${OFFSITE_BACKUP_SECRET}: object storage keys and restic" \
        "                       password, hidden input), saved in ${OFFSITE_SECRETS_FILE}" \
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

# saved_offsite_value <KEY>: value saved in offsite-backup.env, empty when missing.
# The file is read line by line, never sourced: the values are not shell-safe.
saved_offsite_value() {
    [[ -f "$OFFSITE_SECRETS_FILE" ]] || return 0
    awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$OFFSITE_SECRETS_FILE"
}

# check_offsite_value <name> <value>: one line, no surrounding blank (env file format)
check_offsite_value() {
    [[ -n "$2" ]] || die "$1 cannot be empty"
    [[ "$2" =~ ^[^[:space:]](.*[^[:space:]])?$ ]] || die "$1 cannot start or end with a blank"
}

cmd_set_offsite_backup() {
    local access_key="" secret_key="" restic_password="" repeat="" generated=false
    banner "Off-site backup credentials (restic)"
    echo "Object storage keys with read, write and delete access to the bucket of"
    echo "OFFSITE_BACKUP_REPOSITORY (vps/config.env), and the password of the restic repository:"
    echo "without it the off-site backups can never be decrypted. Keep it in a password manager."
    echo "Input is hidden. Enter keeps the saved value; an empty password with nothing saved"
    echo "generates one (for a new repository only)."
    read -r -s -p "Access key ID (AWS_ACCESS_KEY_ID): " access_key
    echo ""
    access_key="${access_key:-$(saved_offsite_value AWS_ACCESS_KEY_ID)}"
    check_offsite_value "the access key ID" "$access_key"
    read -r -s -p "Secret access key (AWS_SECRET_ACCESS_KEY): " secret_key
    echo ""
    secret_key="${secret_key:-$(saved_offsite_value AWS_SECRET_ACCESS_KEY)}"
    check_offsite_value "the secret access key" "$secret_key"
    read -r -s -p "restic repository password (RESTIC_PASSWORD): " restic_password
    echo ""
    if [[ -n "$restic_password" ]]; then
        read -r -s -p "Repeat the password: " repeat
        echo ""
        [[ "$restic_password" == "$repeat" ]] || die "the passwords differ"
    else
        restic_password=$(saved_offsite_value RESTIC_PASSWORD)
        if [[ -z "$restic_password" ]]; then
            restic_password=$(generate_password 48)
            generated=true
        fi
    fi
    check_offsite_value "the restic password" "$restic_password"

    install -d -m 700 "$SECRETS_DIR"
    (
        umask 077
        render_template "$VPS_TEMPLATES_DIR/secrets/offsite-backup.env.tpl" \
            "SAVED_AT=$(date -Iseconds)" OFFSITE_BACKUP_SECRET \
            "AWS_ACCESS_KEY_ID=$access_key" "AWS_SECRET_ACCESS_KEY=$secret_key" \
            "RESTIC_PASSWORD=$restic_password" > "$OFFSITE_SECRETS_FILE.tmp"
    )
    mv "$OFFSITE_SECRETS_FILE.tmp" "$OFFSITE_SECRETS_FILE"
    apply_secret "$PG_NAMESPACE" "$OFFSITE_BACKUP_SECRET" "AWS_ACCESS_KEY_ID=$access_key" \
        "AWS_SECRET_ACCESS_KEY=$secret_key" "RESTIC_PASSWORD=$restic_password"
    ok "Secret $PG_NAMESPACE/$OFFSITE_BACKUP_SECRET updated, saved in $OFFSITE_SECRETS_FILE"
    if [[ "$generated" == "true" ]]; then
        warn "restic password generated: copy it into a password manager now"
        echo "  sudo ./vps/scripts/export-secrets.sh show offsite-backup"
    fi
    echo "The password must open the repository: a new repository is created with it at the first"
    echo "copy (to change it later: restic key passwd, then this command again)."
    echo "Next: OFFSITE_BACKUP_REPOSITORY in vps/config.env, then sudo ./vps/scripts/apply-backups.sh"
}

main() {
    local command="${1:-}"
    case "$command" in
        setup|rotate|set-discord-webhook|set-offsite-backup) ;;
        -h|--help|help|"") usage; exit 0 ;;
        *) usage; die "unknown command: $command" ;;
    esac
    require_root
    use_k3s_kubeconfig

    case "$command" in
        setup) cmd_setup ;;
        rotate) cmd_rotate ;;
        set-discord-webhook) cmd_set_discord_webhook ;;
        set-offsite-backup) cmd_set_offsite_backup ;;
    esac
}

main "$@"
