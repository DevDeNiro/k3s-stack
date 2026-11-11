#!/bin/bash
set -euo pipefail

# =============================================================================
# Public exposure of the cluster, declared in vps/config.env and rendered from
# vps/templates/:
#   - Gateway infrastructure-gateway: HTTP listener (ACME, redirects) and one
#     HTTPS listener per hostname of GATEWAY_HOSTNAMES (<hostname>=<namespace>),
#     which only accepts the HTTPRoutes of the namespaces declared for it
#   - one Let's Encrypt Certificate per hostname (removed hostnames are pruned)
#   - HTTPRoute https-redirect: HTTP -> HTTPS
#   - HTTPRoutes keycloak (/realms, master realm blocked) and keycloak-resources
#     (/resources) for AUTH_HOSTNAMES, and the RateLimitPolicy keycloak of the
#     OIDC endpoints (KEYCLOAK_RATE_LIMIT_RATE, KEYCLOAK_RATE_LIMIT_BURST)
#   - ConfigMap kube-system/coredns-custom: pods resolve the public hostnames
#     to the gateway (hairpin)
# Run it again after changing GATEWAY_HOSTNAMES, AUTH_HOSTNAMES or the Keycloak
# rate limit.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TLS=true
DRY_RUN=false
CLUSTER_ISSUER="letsencrypt-prod"
GATEWAY_NAMESPACE="nginx-gateway"
GATEWAY_NAME="infrastructure-gateway"
TEMPLATES="$VPS_TEMPLATES_DIR"

usage() {
    printf '%s\n' \
        "Usage: sudo $0 [--staging] [--no-tls] [--dry-run]" \
        "" \
        "Renders and applies the Gateway, certificates, HTTPS redirection, Keycloak routes and" \
        "rate limit, and CoreDNS hairpin from GATEWAY_HOSTNAMES, AUTH_HOSTNAMES and" \
        "KEYCLOAK_RATE_LIMIT_* (vps/config.env). Each HTTPS listener only accepts the routes" \
        "of the namespaces declared for its hostname (<hostname>=<namespace>)." \
        "" \
        "  --staging  Let's Encrypt staging certificates (untrusted, for tests: no rate limit)" \
        "  --no-tls   HTTP only: no HTTPS listener, certificate or redirection, and every" \
        "             namespace routes any hostname on port 80 (tests only)" \
        "  --dry-run  print the rendered manifests without applying them"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --staging) CLUSTER_ISSUER="letsencrypt-staging" ;;
            --no-tls) TLS=false ;;
            --dry-run) DRY_RUN=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

# apply_manifest: applies stdin, or prints it with --dry-run
apply_manifest() {
    if [[ "$DRY_RUN" == "true" ]]; then
        cat
    else
        kubectl apply -f -
    fi
}

# render_hostnames <host>...: HTTPRoute hostnames list items
render_hostnames() {
    local host
    for host in "$@"; do
        render_template "$TEMPLATES/gateway/hostname-item.yaml.tpl" "HOST=$host"
    done
}

# render_listener_refs <listener>...: HTTPRoute parentRefs list items
render_listener_refs() {
    local listener
    for listener in "$@"; do
        render_template "$TEMPLATES/gateway/listener-ref.yaml.tpl" "LISTENER=$listener"
    done
}

# quoted_list <word>...: "a", "b" (items of a YAML flow sequence)
quoted_list() {
    local item list=""
    for item in "$@"; do
        list="${list:+$list, }\"$item\""
    done
    echo "$list"
}

# warn_missing_owners: namespaces of GATEWAY_HOSTNAMES that do not exist yet:
# their hostname serves nothing until the application is onboarded
warn_missing_owners() {
    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    local host namespace
    for host in $(gateway_hosts); do
        for namespace in $(gateway_host_namespaces "$host"); do
            kubectl get namespace "$namespace" >/dev/null 2>&1 \
                || warn "$host: namespace $namespace does not exist yet (sudo ./vps/scripts/onboard-app.sh <app>)"
        done
    done
}

apply_gateway() {
    step "Gateway ${GATEWAY_NAME}"
    local host slug listeners="" http_from="Same"
    if [[ "$TLS" == "true" ]]; then
        for host in $(gateway_hosts); do
            slug=$(hostname_slug "$host")
            # shellcheck disable=SC2046  # word splitting of the namespace list
            listeners+="$(render_template "$TEMPLATES/gateway/https-listener.yaml.tpl" \
                "HOST=$host" "HOST_SLUG=$slug" \
                "ALLOWED_NAMESPACES=$(quoted_list $(gateway_host_namespaces "$host"))")"$'\n'
        done
    else
        # HTTP only: the applications route on the http listener
        http_from="All"
        warn "--no-tls: every namespace can route any hostname on port 80 (tests only)"
    fi
    render_template "$TEMPLATES/gateway/gateway.yaml.tpl" \
        "HTTP_ROUTES_FROM=$http_from" "HTTPS_LISTENERS=$listeners" | apply_manifest
}

apply_certificates() {
    if [[ "$TLS" != "true" ]]; then
        return 0
    fi
    step "Certificates (${CLUSTER_ISSUER})"
    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl get clusterissuer "$CLUSTER_ISSUER" >/dev/null 2>&1 \
            || die "ClusterIssuer $CLUSTER_ISSUER not found (installed by vps/install.sh)"
    fi

    local host slug wanted="" cert
    for host in $(gateway_hosts); do
        slug=$(hostname_slug "$host")
        wanted="$wanted tls-${slug}"
        render_template "$TEMPLATES/cert-manager/certificate.yaml.tpl" \
            "HOST=$host" "HOST_SLUG=$slug" CLUSTER_ISSUER | apply_manifest
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    # Certificates of hostnames removed from GATEWAY_HOSTNAMES
    for cert in $(kubectl get certificates -n "$GATEWAY_NAMESPACE" \
        -l app.kubernetes.io/component=gateway-certificate \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        # shellcheck disable=SC2086  # word splitting of the certificate list
        if ! list_contains "$cert" $wanted; then
            kubectl delete certificate "$cert" -n "$GATEWAY_NAMESPACE"
            kubectl delete secret "$cert" -n "$GATEWAY_NAMESPACE" --ignore-not-found
            ok "Certificate $cert removed"
        fi
    done
}

apply_https_redirect() {
    if [[ "$TLS" != "true" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl delete httproute https-redirect -n "$GATEWAY_NAMESPACE" --ignore-not-found
        fi
        return 0
    fi
    step "HTTP to HTTPS redirection"
    local hostnames
    # shellcheck disable=SC2046  # word splitting of the hostname list
    hostnames=$(render_hostnames $(gateway_hosts))
    render_template "$TEMPLATES/gateway/https-redirect.yaml.tpl" "HOSTNAMES=$hostnames" | apply_manifest
}

# delete_keycloak_rate_limit: removes the RateLimitPolicy (missing CRD tolerated)
delete_keycloak_rate_limit() {
    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl delete ratelimitpolicy keycloak -n security --ignore-not-found 2>/dev/null || true
    fi
}

apply_keycloak_route() {
    if [[ -z "${AUTH_HOSTNAMES:-}" ]]; then
        delete_keycloak_rate_limit
        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl delete httproute keycloak keycloak-resources -n security --ignore-not-found
        fi
        return 0
    fi
    if [[ "$DRY_RUN" != "true" ]] && ! kubectl get service keycloak -n security >/dev/null 2>&1; then
        warn "Keycloak is not installed: route skipped"
        return 0
    fi
    step "Keycloak routes"
    local listeners="http" host parent_refs hostnames
    if [[ "$TLS" == "true" ]]; then
        listeners=""
        for host in $AUTH_HOSTNAMES; do
            listeners="$listeners https-$(hostname_slug "$host")"
        done
    fi
    # shellcheck disable=SC2086  # word splitting of the lists
    parent_refs=$(render_listener_refs $listeners)
    # shellcheck disable=SC2086
    hostnames=$(render_hostnames $AUTH_HOSTNAMES)
    render_template "$TEMPLATES/gateway/keycloak-route.yaml.tpl" \
        "PARENT_REFS=$parent_refs" "HOSTNAMES=$hostnames" | apply_manifest
    apply_keycloak_rate_limit
}

# apply_keycloak_rate_limit: RateLimitPolicy of the HTTPRoute keycloak, removed
# with KEYCLOAK_RATE_LIMIT_RATE=off
apply_keycloak_rate_limit() {
    if [[ "$(keycloak_rate_limit_rate)" == "off" ]]; then
        delete_keycloak_rate_limit
        warn "Keycloak rate limit disabled (KEYCLOAK_RATE_LIMIT_RATE=off)"
        return 0
    fi
    if [[ "$DRY_RUN" != "true" ]] && ! kubectl get crd ratelimitpolicies.gateway.nginx.org >/dev/null 2>&1; then
        warn "RateLimitPolicy CRD missing (NGINX Gateway Fabric 2.4 or later, installed by vps/install.sh): rate limit skipped"
        return 0
    fi
    step "Keycloak rate limit ($(keycloak_rate_limit_rate), burst $(keycloak_rate_limit_burst), per client address)"
    render_keycloak_rate_limit | apply_manifest
}

# gateway_service: data plane Service created by NGINX Gateway Fabric for the
# Gateway, empty until NGF has provisioned it
gateway_service() {
    kubectl get services -n "$GATEWAY_NAMESPACE" \
        -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $1}' || true
}

apply_hairpin() {
    step "CoreDNS hairpin (in-cluster resolution of the public hostnames)"
    local service="" target host rules=""
    if [[ "$DRY_RUN" == "true" ]]; then
        service="<gateway-service>"
    else
        for _ in $(seq 1 30); do
            service=$(gateway_service)
            [[ -n "$service" ]] && break
            sleep 2
        done
        [[ -n "$service" ]] || die "the gateway Service does not exist: kubectl describe gateway $GATEWAY_NAME -n $GATEWAY_NAMESPACE"
    fi
    target="${service}.${GATEWAY_NAMESPACE}.svc.cluster.local"

    for host in $(gateway_hosts); do
        rules+="$(render_template "$TEMPLATES/coredns/rewrite-rule.tpl" \
            "HOST=$host" "GATEWAY_SERVICE=$target")"$'\n'
    done
    render_template "$TEMPLATES/coredns/hairpin.yaml.tpl" "REWRITE_RULES=$rules" | apply_manifest

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl rollout restart deployment/coredns -n kube-system >/dev/null
        kubectl rollout status deployment/coredns -n kube-system --timeout=120s >/dev/null
        ok "Pods resolve the public hostnames to ${target}"
    fi
}

wait_certificates() {
    if [[ "$TLS" != "true" || "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    step "Waiting for the certificates (DNS must point to this server)"
    if kubectl wait --for=condition=Ready certificates -n "$GATEWAY_NAMESPACE" \
        -l app.kubernetes.io/component=gateway-certificate --timeout=180s >/dev/null 2>&1; then
        ok "Certificates issued"
    else
        warn "Some certificates are not issued yet:"
        kubectl get certificates -n "$GATEWAY_NAMESPACE"
        echo "  Diagnose: kubectl describe certificate <name> -n $GATEWAY_NAMESPACE; kubectl get challenges -A"
    fi
}

main() {
    parse_args "$@"
    if [[ "$DRY_RUN" != "true" ]]; then
        require_root
    fi
    load_config
    require_config GATEWAY_HOSTNAMES
    validate_gateway_config
    validate_keycloak_config
    use_k3s_kubeconfig

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl get gatewayclass nginx >/dev/null 2>&1 \
            || die "GatewayClass nginx not found: NGINX Gateway Fabric is installed by vps/install.sh"
    fi

    warn_missing_owners
    apply_gateway
    apply_certificates
    apply_https_redirect
    apply_keycloak_route
    apply_hairpin
    wait_certificates

    if [[ "$DRY_RUN" != "true" ]]; then
        banner "Gateway ready"
        kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE"
        kubectl get httproutes -A
        echo ""
        echo "Applications attach their HTTPRoutes to the Gateway, from the namespace declared"
        echo "for their hostname in GATEWAY_HOSTNAMES (other routes: NotAllowedByListeners):"
        echo "  parentRefs: [{ name: ${GATEWAY_NAME}, namespace: ${GATEWAY_NAMESPACE} }]"
    fi
}

main "$@"
