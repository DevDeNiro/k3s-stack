# =============================================================================
# Kubeconfig of the deployer ServiceAccount of ${NAMESPACE}
# Written by vps/scripts/onboard-app.sh --with-cicd into /root/.k3s-secrets/kubeconfigs/.
# The API is not public: use an SSH tunnel or an --allow-api-from network.
# =============================================================================
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${API_CA_DATA}
contexts:
  - name: ${NAMESPACE}
    context:
      cluster: k3s
      namespace: ${NAMESPACE}
      user: deployer
current-context: ${NAMESPACE}
users:
  - name: deployer
    user:
      token: ${DEPLOYER_TOKEN}
