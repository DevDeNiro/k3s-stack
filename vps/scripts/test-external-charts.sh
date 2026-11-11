#!/bin/bash
set -euo pipefail

# Render exactly the charts, releases and value-file order used by both installers.
# All Helm state and generated manifests stay in a private temporary directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$VPS_DIR/.." && pwd)"
# shellcheck source=../config/versions.env
source "$VPS_DIR/config/versions.env"

for cmd in helm ruby; do
    command -v "$cmd" >/dev/null || { printf '%s is required\n' "$cmd" >&2; exit 1; }
done
umask 077
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
export HELM_CONFIG_HOME="$workdir/config"
export HELM_CACHE_HOME="$workdir/cache"
export HELM_DATA_HOME="$workdir/data"
export HELM_REPOSITORY_CONFIG="$HELM_CONFIG_HOME/repositories.yaml"
export HELM_REPOSITORY_CACHE="$HELM_CACHE_HOME/repository"

while read -r name url; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    helm repo add "$name" "$url" >/dev/null
done < "$VPS_DIR/config/helm-repositories"
helm repo update >/dev/null

kube_version="${K3S_VERSION%%+*}"
render() {
    local label="$1" release="$2" chart="$3" version="$4" namespace="$5"
    shift 5
    printf 'Rendering %s (%s)...\n' "$label" "$version"
    helm template "$release" "$chart" --version "$version" --namespace "$namespace" \
        --kube-version "$kube_version" --include-crds \
        --api-versions gateway.networking.k8s.io/v1 \
        --api-versions gateway.networking.k8s.io/v1/Gateway \
        "$@" > "$workdir/$label.yaml"
}

render vps-nginx nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric "$NGINX_GATEWAY_FABRIC_VERSION" nginx-gateway \
    -f "$VPS_DIR/values/nginx-gateway-fabric.yaml"
render local-nginx nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric "$NGINX_GATEWAY_FABRIC_VERSION" nginx-gateway \
    -f "$ROOT_DIR/local/values/nginx-gateway-fabric.yaml"
render vps-cert-manager cert-manager jetstack/cert-manager "$CERT_MANAGER_VERSION" cert-manager \
    -f "$VPS_DIR/values/cert-manager.yaml"
render vps-postgresql postgresql oci://registry-1.docker.io/bitnamicharts/postgresql "$POSTGRESQL_CHART_VERSION" storage \
    -f "$VPS_DIR/values/postgresql.yaml" -f "$VPS_DIR/values/postgresql-image.yaml"
render local-postgresql postgresql oci://registry-1.docker.io/bitnamicharts/postgresql "$POSTGRESQL_CHART_VERSION" storage \
    -f "$VPS_DIR/values/postgresql.yaml" -f "$ROOT_DIR/local/values/postgresql.yaml" -f "$VPS_DIR/values/postgresql-image.yaml"
render vps-prometheus prometheus prometheus-community/prometheus "$PROMETHEUS_CHART_VERSION" monitoring \
    -f "$VPS_DIR/values/prometheus.yaml"
render local-prometheus prometheus prometheus-community/prometheus "$PROMETHEUS_CHART_VERSION" monitoring \
    -f "$ROOT_DIR/local/values/prometheus.yaml"
render vps-grafana grafana grafana-community/grafana "$GRAFANA_CHART_VERSION" monitoring \
    -f "$VPS_DIR/values/grafana.yaml"
render local-grafana grafana grafana-community/grafana "$GRAFANA_CHART_VERSION" monitoring \
    -f "$ROOT_DIR/local/values/grafana.yaml"
render vps-loki loki grafana-community/loki "$LOKI_CHART_VERSION" monitoring \
    -f "$VPS_DIR/values/loki.yaml"
render vps-alloy alloy grafana/alloy "$ALLOY_CHART_VERSION" monitoring \
    -f "$VPS_DIR/values/alloy.yaml"
render vps-sealed-secrets sealed-secrets sealed-secrets/sealed-secrets "$SEALED_SECRETS_CHART_VERSION" kube-system \
    -f "$VPS_DIR/values/sealed-secrets.yaml"
render local-sealed-secrets sealed-secrets sealed-secrets/sealed-secrets "$SEALED_SECRETS_CHART_VERSION" kube-system \
    -f "$ROOT_DIR/local/values/sealed-secrets.yaml"
render vps-argocd argocd argo/argo-cd "$ARGOCD_CHART_VERSION" argocd \
    -f "$VPS_DIR/values/argocd.yaml"
render local-argocd argocd argo/argo-cd "$ARGOCD_CHART_VERSION" argocd \
    -f "$ROOT_DIR/local/values/argocd.yaml"
render vps-image-updater argocd-image-updater argo/argocd-image-updater "$ARGOCD_IMAGE_UPDATER_CHART_VERSION" argocd \
    -f "$VPS_DIR/values/argocd-image-updater.yaml"

ruby "$SCRIPT_DIR/verify-external-charts.rb" "$workdir" "$ROOT_DIR"
printf 'External Helm chart checks passed; no cluster was contacted.\n'
