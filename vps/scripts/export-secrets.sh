#!/bin/bash
set -euo pipefail

# =============================================================================
# Credentials and secret operations of the stack (root only): display of the
# generated credentials, Sealed Secrets certificate and key backup, repository
# access of Argo CD and read-only image pull access.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SEALING_KEY_LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"
SEALING_CONTROLLER="sealed-secrets-controller"
SEALING_BACKUP_DIR="$BACKUP_DIR/sealed-secrets"
# Key backups: AES-256-CBC, PBKDF2 key derivation. Passphrase prompted, or read
# from the SEALING_KEY_PASSPHRASE environment variable (never from arguments).
OPENSSL_CIPHER=(-aes-256-cbc -pbkdf2 -iter 600000 -md sha256)

usage() {
    printf '%s\n' \
        "Usage: sudo $0 <command> [arguments]" \
        "" \
        "Commands:" \
        "  show [service]                        generated credentials; service: postgres, keycloak," \
        "                                        grafana, argocd, offsite-backup, or an onboarded" \
        "                                        application name" \
        "  export-cert <dest>                    Sealed Secrets public certificate (for kubeseal)" \
        "  backup-sealing-key [dest]             encrypted backup of the Sealed Secrets private keys" \
        "                                        (default: ${SEALING_BACKUP_DIR}/sealed-secrets-keys-<date>.enc)" \
        "  restore-sealing-key <file>            restore keys from a backup, restart the controller" \
        "  fetch-from-k8s <secret> <namespace>   decoded content of a Kubernetes Secret" \
        "  set-scm-credentials <github|gitlab>   repository access of Argo CD for every organization" \
        "                                        of SCM_ORGANIZATIONS, namespace argocd only" \
        "                                        (hidden token input)" \
        "  set-registry-credentials              read-only image pull access: Argo CD Image Updater," \
        "                                        Keycloak extension images and every application" \
        "                                        namespace (hidden token input)" \
        "" \
        "Environment: SEALING_KEY_PASSPHRASE  passphrase of the key backups (prompted when unset)"
}

# -----------------------------------------------------------------------------
# Credentials
# -----------------------------------------------------------------------------
cmd_show() {
    local service="${1:-all}" file="$SECRETS_DIR/credentials.env" prefix=""
    case "$service" in
        all) prefix="" ;;
        postgres|postgresql) prefix="POSTGRES_" ;;
        keycloak) prefix="KEYCLOAK_" ;;
        grafana) prefix="GRAFANA_" ;;
        argocd|argo) prefix="ARGOCD_" ;;
        *) file="$SECRETS_DIR/${service}.env" ;;
    esac
    [[ -f "$file" ]] || die "$file not found (unknown service or application)"
    if [[ -n "$prefix" ]]; then
        grep -E "^${prefix}" "$file"
    else
        grep -Ev '^\s*(#|$)' "$file"
    fi
    warn "Do not share or screenshot these values"
}

cmd_fetch_from_k8s() {
    local secret="${1:-}" namespace="${2:-}" key
    [[ -n "$secret" && -n "$namespace" ]] || die "usage: $0 fetch-from-k8s <secret> <namespace>"
    kubectl get secret "$secret" -n "$namespace" >/dev/null || exit 1
    for key in $(kubectl get secret "$secret" -n "$namespace" -o json | jq -r '.data | keys[]'); do
        echo -e "${GREEN}${key}${NC}=$(secret_value "$namespace" "$secret" "$key")"
    done
}

# -----------------------------------------------------------------------------
# Sealed Secrets
# -----------------------------------------------------------------------------
cmd_export_cert() {
    local dest="${1:-}"
    [[ -n "$dest" ]] || die "usage: $0 export-cert <dest>"
    # The controller seals with its newest active key
    kubectl get secrets -n kube-system -l "$SEALING_KEY_LABEL=active" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].data.tls\.crt}' | base64 -d > "$dest"
    [[ -s "$dest" ]] || die "no active Sealed Secrets key found"
    chmod 644 "$dest"
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER" "$dest"
    fi
    ok "Public certificate exported: $dest"
    openssl x509 -in "$dest" -noout -fingerprint -sha256
}

# print_key_fingerprints <keys-json>
print_key_fingerprints() {
    local name
    for name in $(echo "$1" | jq -r '.items[].metadata.name'); do
        echo "  $name: $(echo "$1" | jq -r --arg name "$name" \
            '.items[] | select(.metadata.name == $name) | .data["tls.crt"]' \
            | base64 -d | openssl x509 -noout -fingerprint -sha256 -enddate | tr '\n' ' ')"
    done
}

# openssl_passphrase: passphrase option of openssl (environment variable or prompt)
openssl_passphrase() {
    if [[ -n "${SEALING_KEY_PASSPHRASE:-}" ]]; then
        echo "-pass env:SEALING_KEY_PASSPHRASE"
    fi
}

cmd_backup_sealing_key() {
    local dest="${1:-$SEALING_BACKUP_DIR/sealed-secrets-keys-$(date -u +%Y%m%d-%H%M%S).enc}" keys
    keys=$(kubectl get secrets -n kube-system -l "$SEALING_KEY_LABEL" -o json | jq '{
        apiVersion: "v1",
        kind: "List",
        items: [.items[] | {apiVersion, kind, type, data,
            metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels}}]
    }')
    [[ "$(echo "$keys" | jq '.items | length')" -gt 0 ]] || die "no Sealed Secrets key found in kube-system"

    step "Backing up the Sealed Secrets keys"
    print_key_fingerprints "$keys"
    install -d -m 700 "$(dirname "$dest")"
    # shellcheck disable=SC2046  # optional "-pass env:..." option
    printf '%s' "$keys" | openssl enc "${OPENSSL_CIPHER[@]}" -salt $(openssl_passphrase) -out "$dest"
    chmod 600 "$dest"
    ok "Encrypted backup: $dest"
    echo "Copy it off the server and keep the passphrase elsewhere (password manager):"
    echo "  ssh <vps> \"sudo cat $dest\" > $(basename "$dest")"
}

cmd_restore_sealing_key() {
    local file="${1:-}" keys
    [[ -f "$file" ]] || die "usage: $0 restore-sealing-key <file>"
    # shellcheck disable=SC2046  # optional "-pass env:..." option
    keys=$(openssl enc -d "${OPENSSL_CIPHER[@]}" $(openssl_passphrase) -in "$file") \
        || die "decryption failed (wrong passphrase?)"
    echo "$keys" | jq -e '.kind == "List" and (.items | length > 0)' >/dev/null 2>&1 \
        || die "$file is not a Sealed Secrets key backup"

    step "Restoring the Sealed Secrets keys"
    print_key_fingerprints "$keys"
    confirm "Restore these keys into kube-system and restart the controller?" || die "aborted"
    printf '%s' "$keys" | kubectl apply -f -
    kubectl rollout restart "deployment/$SEALING_CONTROLLER" -n kube-system
    kubectl rollout status "deployment/$SEALING_CONTROLLER" -n kube-system --timeout=120s
    ok "Keys restored: SealedSecrets sealed with them are decrypted again"
}

# -----------------------------------------------------------------------------
# Repository access (Argo CD) and image pull access (Image Updater, Keycloak
# extensions, application namespaces): two tokens. The repository token stays in
# the namespace argocd. The pull token is copied into every application
# namespace, where any chart of the application can read it: read-only.
# -----------------------------------------------------------------------------
# default_credentials_url <provider> <organization>...: URL prefix of the Argo CD
# credential template, matched against the repository URLs: the organization
# itself, or the whole provider when several organizations share the token
default_credentials_url() {
    local provider="$1"
    shift
    case $# in
        0) echo "" ;;
        1) echo "https://${provider}.com/$1" ;;
        *) echo "https://${provider}.com/" ;;
    esac
}

cmd_set_scm_credentials() {
    local provider="${1:-}" default_url="" url token username org organizations=""
    case "$provider" in
        github) username="git" ;;
        gitlab) username="oauth2" ;;
        *) die "usage: $0 set-scm-credentials <github|gitlab>" ;;
    esac
    if [[ -f "$VPS_CONFIG_FILE" ]]; then
        load_config
        organizations=$(scm_organizations)
        # shellcheck disable=SC2086  # word splitting of the organization list
        default_url=$(default_credentials_url "$provider" $organizations)
    fi

    banner "Repository access for Argo CD ($provider)"
    echo "One token for every organization${organizations:+ ($organizations)}, kept in the namespace"
    echo "argocd only (never copied into an application namespace):"
    echo "  GitHub: classic personal access token with the scope 'repo', of a machine account that is"
    echo "  a read-only member of the organizations: the scope only grants the rights of the account."
    echo "  A fine-grained token is limited to one owner. For an organization enforcing SAML SSO,"
    echo "  authorize the token for it."
    echo "  GitLab: 'read_repository'."
    echo "Image pull access is a separate, read-only token: export-secrets.sh set-registry-credentials."
    read -r -p "Repository URL prefix covering every organization [$default_url]: " url
    url="${url:-$default_url}"
    [[ -n "$url" ]] || die "the URL cannot be empty"
    for org in $organizations; do
        case "$(lowercase "https://${provider}.com/${org}/")" in
            "$(lowercase "$url")"*) ;;
            *) warn "$url does not cover $org: its repositories rely on the repository Secrets of onboard-app.sh" ;;
        esac
    done
    read -r -s -p "Token: " token
    echo ""
    [[ -n "$token" ]] || die "the token cannot be empty"

    # Credential template: Argo CD matches its URL as a prefix of the repository URLs
    apply_secret argocd "${provider}-repo-creds" type=git "url=$url" "username=$username" "password=$token"
    kubectl label secret "${provider}-repo-creds" -n argocd argocd.argoproj.io/secret-type=repo-creds --overwrite >/dev/null
    # Token of every ApplicationSet SCM generator (templates/argocd/generator-*.yaml.tpl)
    apply_secret argocd scm-token "token=$token"
    ok "${provider}-repo-creds ($url) and scm-token created in argocd"
    echo "Repository Secrets of the onboarded applications (repo-<app>): run onboard-app.sh <app>"
    echo "again after a token change."
}

cmd_set_registry_credentials() {
    local registry username="" default_username="" token namespace count=0
    [[ -f "$VPS_CONFIG_FILE" ]] || die "$VPS_CONFIG_FILE not found: cp vps/config.env.example vps/config.env"
    load_config
    registry=$(registry_host)

    banner "Image pull access ($registry)"
    echo "Read-only token: it is copied into every application namespace, where any chart of the"
    echo "application can read it. Never a token that can write."
    case "${SCM_PROVIDER:-github}" in
        github)
            # ghcr.io accepts any username with a personal access token
            default_username="git"
            echo "  GitHub: classic personal access token with the single scope 'read:packages' (GHCR"
            echo "  only accepts classic tokens), of a machine account that can read the packages."
            ;;
        *)
            echo "  GitLab: deploy token or access token with the single scope 'read_registry', and its"
            echo "  username."
            ;;
    esac
    read -r -p "Username${default_username:+ [$default_username]}: " username
    username="${username:-$default_username}"
    [[ -n "$username" ]] || die "the username cannot be empty"
    read -r -s -p "Token: " token
    echo ""
    [[ -n "$token" ]] || die "the token cannot be empty"

    # Argo CD Image Updater (values/argocd-image-updater.yaml), and the copy source
    # of onboard-app.sh
    apply_registry_secret argocd "$REGISTRY_PULL_SECRET" "$registry" "$username" "$token"
    ok "$REGISTRY_PULL_SECRET created in argocd"
    # Private Keycloak extension images (templates/keycloak/extensions-pod.yaml.tpl)
    if kubectl get namespace security >/dev/null 2>&1; then
        apply_registry_secret security "$KEYCLOAK_PULL_SECRET" "$registry" "$username" "$token"
        ok "$KEYCLOAK_PULL_SECRET created in security (Keycloak extension images)"
        if [[ -n "${KEYCLOAK_EXTENSION_IMAGES:-}" ]]; then
            echo "  Keycloak pulls its extension images at its next start: sudo ./vps/scripts/apply-keycloak.sh"
        fi
    fi
    # Application namespaces (onboard-app.sh): a rotation replaces the token everywhere
    for namespace in $(kubectl get namespaces -l app.kubernetes.io/managed-by=k3s-stack \
        -o jsonpath='{.items[*].metadata.name}'); do
        apply_registry_secret "$namespace" "$APP_PULL_SECRET" "$registry" "$username" "$token"
        count=$((count + 1))
    done
    ok "$APP_PULL_SECRET updated in $count application namespace(s)"
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$command" in
        show|export-cert|backup-sealing-key|restore-sealing-key|fetch-from-k8s|set-scm-credentials|set-registry-credentials) ;;
        -h|--help|help|"") usage; exit 0 ;;
        *) usage; die "unknown command: $command" ;;
    esac
    require_root
    use_k3s_kubeconfig

    case "$command" in
        show) cmd_show "$@" ;;
        export-cert) cmd_export_cert "$@" ;;
        backup-sealing-key) cmd_backup_sealing_key "$@" ;;
        restore-sealing-key) cmd_restore_sealing_key "$@" ;;
        fetch-from-k8s) cmd_fetch_from_k8s "$@" ;;
        set-scm-credentials) cmd_set_scm_credentials "$@" ;;
        set-registry-credentials) cmd_set_registry_credentials ;;
    esac
}

main "$@"
