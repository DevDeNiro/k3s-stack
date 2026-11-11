#!/bin/bash
set -euo pipefail

# =============================================================================
# Onboards an application, per environment (<app>-alpha, <app>-prod):
#   - namespace, ResourceQuota, LimitRange, Pod Security level and default
#     NetworkPolicy (templates/onboarding/namespace.yaml.tpl,
#     config/onboarding/<env>.env)
#   - PostgreSQL role and database <app>-<env>, closed to the other roles, and
#     the Secret <app>-db; an existing password is never changed
#   - image pull Secret ghcr-secret, copied from argocd/ghcr-registry-secret
#     (read-only token of export-secrets.sh set-registry-credentials)
# then, once for the application:
#   - the Argo CD repository Secret of <organization>/<app> (--organization,
#     default: first of SCM_ORGANIZATIONS)
#   - last, the Argo CD AppProject <app> (templates/onboarding/appproject.yaml.tpl):
#     the ApplicationSets deploy the application from then on
# Public hostnames are declared in config.env (GATEWAY_HOSTNAMES,
# <hostname>=<app>-<env>) and served by setup-gateway-api.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_NAME=""
TARGET_ENVS=(alpha prod)
SKIP_DATABASE=false
APP_SECRETS_FILE=""
ORGANIZATION=""

usage() {
    printf '%s\n' \
        "Usage: sudo $0 <app-name> [--environment all|alpha|prod] [--organization ORG]" \
        "                          [--skip-database]" \
        "" \
        "Creates, for each environment (<app>-alpha, <app>-prod): the namespace with its quota," \
        "Pod Security level and default NetworkPolicy, the PostgreSQL database and Secret <app>-db," \
        "the image pull Secret ghcr-secret. Then the Argo CD repository Secret and, last, the" \
        "AppProject that lets Argo CD deploy the application." \
        "" \
        "  --environment ENV   all (default), alpha or prod" \
        "  --organization ORG  organization of the repository, one of SCM_ORGANIZATIONS" \
        "                      (default: the first one)" \
        "  --skip-database     no PostgreSQL role, database or <app>-db Secret" \
        "" \
        "Database passwords: ${SECRETS_DIR}/<app>.env (restore it before onboarding" \
        "again after a reinstallation: existing passwords are kept)." \
        "Onboarding again is safe: it applies the current templates and keeps the passwords."
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
            --organization|--org)
                [[ -n "${2:-}" ]] || die "--organization expects an organization of SCM_ORGANIZATIONS"
                ORGANIZATION="$2"
                shift
                ;;
            --skip-database) SKIP_DATABASE=true ;;
            --with-cicd)
                die "--with-cicd was removed: Argo CD pulls the deployments, no long-lived cluster token is handed out (vps/docs/security-hardening.md)"
                ;;
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
    # The Argo CD project of the application bears its name, and "default" is the
    # emptied project of Argo CD (manifests/argocd-default-project.yaml)
    [[ "$APP_NAME" != "default" ]] || die "application name: 'default' is reserved (Argo CD project)"
    APP_SECRETS_FILE="$SECRETS_DIR/${APP_NAME}.env"
}

# resolve_organization: --organization, or the first organization of
# SCM_ORGANIZATIONS; it must belong to the list (case-insensitive, as GitHub)
resolve_organization() {
    local org first=""
    for org in $(scm_organizations); do
        [[ -n "$first" ]] || first="$org"
        if [[ -n "$ORGANIZATION" && "$(lowercase "$org")" == "$(lowercase "$ORGANIZATION")" ]]; then
            ORGANIZATION="$org"
            return 0
        fi
    done
    [[ -z "$ORGANIZATION" ]] \
        || die "--organization $ORGANIZATION is not listed in SCM_ORGANIZATIONS ($(scm_organizations))"
    ORGANIZATION="$first"
}

# repository_url: Git URL of the repository of the application
repository_url() {
    echo "https://${SCM_PROVIDER}.com/${ORGANIZATION}/${APP_NAME}.git"
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

# create_pull_secrets: image pull Secret of each namespace, copied from the one of
# Argo CD Image Updater. It holds the read-only registry token, never the
# repository token: any chart of the application can read the Secrets of its
# namespaces.
create_pull_secrets() {
    step "Image pull Secret"
    local config env
    config=$(secret_value argocd "$REGISTRY_PULL_SECRET" .dockerconfigjson)
    if [[ -z "$config" ]]; then
        warn "No argocd/${REGISTRY_PULL_SECRET}: run export-secrets.sh set-registry-credentials, then onboard again"
        return 0
    fi
    for env in "${TARGET_ENVS[@]}"; do
        apply_dockerconfig_secret "${APP_NAME}-${env}" "$APP_PULL_SECRET" "$config"
    done
    ok "${APP_PULL_SECRET} in ${TARGET_ENVS[*]/#/${APP_NAME}-}"
}

# create_repository_secret: Argo CD access to the repository of the application,
# with the repository token of export-secrets.sh set-scm-credentials (namespace
# argocd only)
create_repository_secret() {
    step "Argo CD repository access"
    local creds="${SCM_PROVIDER}-repo-creds" token username repo_url
    token=$(secret_value argocd "$creds" password)
    if [[ -z "$token" ]]; then
        warn "No $creds Secret: run export-secrets.sh set-scm-credentials $SCM_PROVIDER, then onboard again"
        return 0
    fi
    username=$(secret_value argocd "$creds" username)
    repo_url=$(repository_url)
    apply_secret argocd "repo-${APP_NAME}" type=git "url=$repo_url" "username=${username:-git}" "password=$token"
    kubectl label secret "repo-${APP_NAME}" -n argocd argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
    ok "Argo CD repository Secret repo-${APP_NAME} ($repo_url)"
}

# create_project: Argo CD AppProject of the application, applied last: the
# ApplicationSets deploy the application from then on (within 3 minutes), with
# everything it needs already in place
create_project() {
    step "Argo CD project ${APP_NAME}"
    if ! kubectl get crd appprojects.argoproj.io >/dev/null 2>&1; then
        warn "Argo CD is not installed: no AppProject"
        return 0
    fi
    render_template "$VPS_TEMPLATES_DIR/onboarding/appproject.yaml.tpl" \
        APP_NAME "REPO_URL=$(repository_url)" | kubectl apply -f -
    ok "AppProject ${APP_NAME}: repository $(repository_url), namespaces ${APP_NAME}-alpha and ${APP_NAME}-prod"
}

print_summary() {
    banner "${APP_NAME} onboarded (${TARGET_ENVS[*]})"
    echo "Next steps:"
    echo "  - declare its public hostnames in GATEWAY_HOSTNAMES (vps/config.env), each one with the"
    echo "    namespace allowed to route it (<hostname>=${APP_NAME}-prod, <hostname>=${APP_NAME}-alpha), then:"
    echo "      sudo ./vps/scripts/setup-gateway-api.sh"
    echo "  - attach its HTTPRoutes to the Gateway infrastructure-gateway (namespace nginx-gateway)"
    echo "  - Argo CD deploys helm/${APP_NAME} from ${ORGANIZATION}/${APP_NAME} within 3 minutes:"
    echo "    main -> prod, develop -> alpha when the repository has a develop branch"
    echo "    (image $(image_base "$ORGANIZATION")/${APP_NAME}, AppProject ${APP_NAME})"
}

main() {
    parse_args "$@"
    require_root
    load_config
    require_config SCM_PROVIDER
    validate_scm_config
    resolve_organization
    use_k3s_kubeconfig
    umask 077

    banner "Onboarding ${APP_NAME} (${TARGET_ENVS[*]}, organization ${ORGANIZATION})"
    create_namespaces
    create_databases
    create_pull_secrets
    create_repository_secret
    create_project
    print_summary
}

main "$@"
