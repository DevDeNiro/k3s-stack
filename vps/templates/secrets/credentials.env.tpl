# =============================================================================
# k3s-stack infrastructure credentials - generated on ${GENERATED_AT}
# Written by vps/scripts/setup-secrets.sh into /root/.k3s-secrets/credentials.env (root only).
# Display: sudo ./vps/scripts/export-secrets.sh show
# =============================================================================

# PostgreSQL superuser (namespace: storage)
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD}

# Keycloak bootstrap admin and database user (namespace: security)
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KEYCLOAK_DB_PASSWORD=${KEYCLOAK_DB_PASSWORD}

# Grafana admin (namespace: monitoring)
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}

# Argo CD admin (namespace: argocd)
ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD}
