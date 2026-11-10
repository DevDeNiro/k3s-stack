#!/bin/bash
set -euo pipefail

# =============================================================================
# Onboards an application, per environment (<app>-alpha, <app>-prod):
#   - namespace, ResourceQuota, LimitRange and Pod Security level
#     (templates/onboarding/namespace.yaml.tpl, config/onboarding/<env>.env)
#   - PostgreSQL role and database <app>-<env> and the Secret <app>-db;
#     an existing password is never changed
#   - image pull Secret ghcr-secret and the Argo CD repository Secret
#   - with --with-cicd: a deployer ServiceAccount and its kubeconfig
# Public hostnames are declared in config.env (GATEWAY_HOSTNAMES) and served by
# setup-gateway-api.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_NAME=""
TARGET_ENVS=(alpha prod)
SKIP_DATABASE=false
WITH_CICD=false
APP_SECRETS_FILE=""

usage() {
    printf '%s\n' \
        "Usage: sudo $0 <app-name> [--environment all|alpha|prod] [--skip-database] [--with-cicd]" \
        "" \
        "Creates, for each environment (<app>-alpha, <app>-prod): the namespace with its quota" \
        "and Pod Security level, the PostgreSQL database and Secret <app>-db, the image pull" \
        "Secret ghcr-secret and the Argo CD repository Secret." \
        "" \
        "  --environment ENV  all (default), alpha or prod" \
        "  --skip-database    no PostgreSQL role, database or <app>-db Secret" \
        "  --with-cicd        deployer ServiceAccount and kubeconfig for a CI pipeline" \
        "                     (Argo CD already pulls the deployments)" \
        "" \
        "Database passwords: ${SECRETS_DIR}/<app>.env (restore it before onboarding" \
        "again after a reinstallation: existing passwords are kept)."
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --environment|--env)
                case "${2:-}" in
                    all) TARGET_ENVS=(alpha prod) ;;
                    alpha|prod) TARGET_ENVS=("$2") ;;
                    *) die "--environment expects all, alpha or prod" ;;
                esac
                shift
                ;;
            --skip-database) SKIP_DATABASE=true ;;
            --with-cicd) WITH_CICD=true ;;
            -h|--help) usage; exit 0 ;;
            -*) usage; die "unknown option: $1" ;;
            *)
                [[ -z "$APP_NAME" ]] || die "only one application name"
                APP_NAME="$1"
                ;;
        esac
        shift
    done
    [[ -n "$APP_NAME" ]] || { usage; exit 1; }
    [[ "$APP_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
        || die "application name: lowercase letters, digits and hyphens only"
    APP_SECRETS_FILE="$SECRETS_DIR/${APP_NAME}.env"
}

# -----------------------------------------------------------------------------
# Saved database passwords (<APP>_<ENV>_DB_PASSWORD in /root/.k3s-secrets/<app>.env)
# -----------------------------------------------------------------------------
password_key() {
    echo "${APP_NAME}_${1}_DB_PASSWORD" | tr 'a-z-' 'A-Z_'
}

read_saved_password() {
    [[ -f "$APP_SECRETS_FILE" ]] || return 0
    awk -F= -v key="$(password_key "$1")" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$APP_SECRETS_FILE"
}

save_password() {
    local key tmp
    key=$(password_key "$1")
    tmp=$(mktemp "${APP_SECRETS_FILE}.XXXXXX")
    if [[ -f "$APP_SECRETS_FILE" ]]; then
        awk -F= -v key="$key" '$1 != key' "$APP_SECRETS_FILE" > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$2" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$APP_SECRETS_FILE"
}

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------
create_namespaces() {
    step "Namespaces"
    local env
    for env in "${TARGET_ENVS[@]}"; do
        # Sizing of the environment (config/onboarding/<env>.env), scoped to the subshell
        (
            # shellcheck source=/dev/null
            . "$VPS_CONFIG_DIR/onboarding/${env}.env"
            render_template "$VPS_TEMPLATES_DIR/onboarding/namespace.yaml.tpl" \
                "NAMESPACE=${APP_NAME}-${env}" "APP_ENV=$env" APP_NAME POD_SECURITY_ENFORCE \
                QUOTA_REQUESTS_CPU QUOTA_REQUESTS_MEMORY QUOTA_LIMITS_CPU QUOTA_LIMITS_MEMORY QUOTA_PODS
        ) | kubectl apply -f -
    done
}

ensure_database() {
    local env="$1" name="${APP_NAME}-$1" status role_exists db_exists password="" auth_database
    status=$(pg_admin_exec "$VPS_SQL_DIR/role-database-status.sql" "role=$name" "database=$name")
    role_exists="${status%%|*}"
    db_exists="${status#*|}"

    if kubectl get secret "${APP_NAME}-db" -n "$name" >/dev/null 2>&1; then
        password=$(secret_value "$name" "${APP_NAME}-db" password)
        [[ -n "$password" ]] || die "Secret ${APP_NAME}-db in $name has no password key: refusing to change the role"
    else
        password=$(read_saved_password "$env")
    fi

    if [[ "$role_exists" == "true" ]]; then
        [[ -n "$password" ]] || die "role $name exists but its password is unknown: refusing to change it"
        auth_database="$name"
        [[ "$db_exists" == "true" ]] || auth_database="postgres"
        pg_exec "$name" "$auth_database" "$password" "$VPS_SQL_DIR/ping.sql" >/dev/null \
            || die "the stored password of $name does not authenticate: refusing to change it"
    elif [[ "$db_exists" == "true" && -z "$password" ]]; then
        die "database $name exists without a known owner password: refusing to change it"
    elif [[ -z "$password" ]]; then
        password=$(generate_password 32)
    fi

    pg_admin_exec "$VPS_SQL_DIR/ensure-role-database.sql" \
        "role=$name" "password=$password" "database=$name" reset_password=false
    save_password "$env" "$password"

    if ! kubectl get secret "${APP_NAME}-db" -n "$name" >/dev/null 2>&1; then
        apply_secret "$name" "${APP_NAME}-db" \
            "host=$PG_SERVICE_HOST" port=5432 "database=$name" "username=$name" "password=$password" \
            "url=jdbc:postgresql://${PG_SERVICE_HOST}:5432/${name}?sslmode=require" \
            "r2dbc-url=r2dbc:postgresql://${PG_SERVICE_HOST}:5432/${name}?sslMode=require"
    fi
    ok "Database $name ready, Secret ${APP_NAME}-db in $name"
}

create_databases() {
    if [[ "$SKIP_DATABASE" == "true" ]]; then
        warn "Skipping the databases (--skip-database)"
        return 0
    fi
    step "PostgreSQL databases"
    pg_wait_ready 120s
    install -d -m 700 "$SECRETS_DIR"
    local env
    for env in "${TARGET_ENVS[@]}"; do
        ensure_database "$env"
    done
    echo "  Passwords saved in $APP_SECRETS_FILE: seal them in the application repository for GitOps."
}

create_repository_secrets() {
    step "Registry and repository access"
    local creds="${SCM_PROVIDER}-repo-creds" token username env repo_url
    token=$(secret_value argocd "$creds" password)
    if [[ -z "$token" ]]; then
        warn "No $creds Secret: run export-secrets.sh set-scm-credentials $SCM_PROVIDER, then onboard again"
        return 0
    fi
    username=$(secret_value argocd "$creds" username)

    for env in "${TARGET_ENVS[@]}"; do
        apply_registry_secret "${APP_NAME}-${env}" ghcr-secret "${REGISTRY_BASE%%/*}" "${username:-git}" "$token"
    done
    ok "ghcr-secret (${REGISTRY_BASE%%/*}) in ${TARGET_ENVS[*]/#/${APP_NAME}-}"

    repo_url="https://${SCM_PROVIDER}.com/${SCM_ORGANIZATION}/${APP_NAME}.git"
    apply_secret argocd "repo-${APP_NAME}" type=git "url=$repo_url" "username=${username:-git}" "password=$token"
    kubectl label secret "repo-${APP_NAME}" -n argocd argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
    ok "Argo CD repository Secret repo-${APP_NAME} ($repo_url)"
}

create_cicd_access() {
    if [[ "$WITH_CICD" != "true" ]]; then
        return 0
    fi
    step "CI/CD access (deployer ServiceAccount)"
    local env namespace api_server api_ca_data token dir="$SECRETS_DIR/kubeconfigs"
    api_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    api_ca_data=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
    install -d -m 700 "$dir"

    for env in "${TARGET_ENVS[@]}"; do
        namespace="${APP_NAME}-${env}"
        render_template "$VPS_TEMPLATES_DIR/onboarding/deployer-rbac.yaml.tpl" "NAMESPACE=$namespace" \
            | kubectl apply -f -
        token=""
        for _ in $(seq 1 15); do
            token=$(secret_value "$namespace" deployer-token token)
            [[ -n "$token" ]] && break
            sleep 1
        done
        [[ -n "$token" ]] || die "the token of deployer in $namespace was not issued"
        (
            umask 077
            render_template "$VPS_TEMPLATES_DIR/onboarding/deployer-kubeconfig.yaml.tpl" \
                "NAMESPACE=$namespace" "API_SERVER=$api_server" "API_CA_DATA=$api_ca_data" \
                "DEPLOYER_TOKEN=$token" > "$dir/${namespace}.kubeconfig"
        )
        ok "Kubeconfig: $dir/${namespace}.kubeconfig (export-secrets.sh export-kubeconfig ${APP_NAME} ${env} <dest>)"
    done
}

print_summary() {
    banner "${APP_NAME} onboarded (${TARGET_ENVS[*]})"
    echo "Next steps:"
    echo "  - declare its public hostnames in GATEWAY_HOSTNAMES (vps/config.env), then:"
    echo "      sudo ./vps/scripts/setup-gateway-api.sh"
    echo "  - attach its HTTPRoutes to the Gateway infrastructure-gateway (namespace nginx-gateway)"
    echo "  - Argo CD deploys helm/${APP_NAME} from the repository (develop -> alpha, main -> prod)"
}

main() {
    parse_args "$@"
    require_root
    load_config
    require_config SCM_PROVIDER SCM_ORGANIZATION REGISTRY_BASE
    use_k3s_kubeconfig
    umask 077

    banner "Onboarding ${APP_NAME} (${TARGET_ENVS[*]})"
    create_namespaces
    create_databases
    create_repository_secrets
    create_cicd_access
    print_summary
}

main "$@"
