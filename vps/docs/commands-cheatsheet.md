# K3s Administration Cheatsheet

Commandes essentielles pour administrer le cluster K3s.

## Pods & Déploiements

```bash
# Lister tous les pods
kubectl get pods -A

# Pods d'un namespace
kubectl get pods -n <namespace>

# Détails d'un pod
kubectl describe pod <pod-name> -n <namespace>

# Logs d'un pod
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> -f              # Follow
kubectl logs <pod-name> -n <namespace> --tail=100      # Dernières 100 lignes
kubectl logs <pod-name> -n <namespace> --previous      # Logs du container précédent (crash)

# Logs d'un déploiement
kubectl logs -n <namespace> deploy/<deployment-name>

# Exécuter une commande dans un pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
kubectl exec -it <pod-name> -n <namespace> -- bash

# Redémarrer un déploiement
kubectl rollout restart deployment <name> -n <namespace>

# Statut du rollout
kubectl rollout status deployment <name> -n <namespace>

# Historique des rollouts
kubectl rollout history deployment <name> -n <namespace>

# Rollback
kubectl rollout undo deployment <name> -n <namespace>
```

## Services & Réseau

```bash
# Lister les services
kubectl get svc -A

# Port-forward (accès local)
kubectl port-forward -n <namespace> svc/<service> <local-port>:<service-port>

# Exemples
kubectl port-forward -n monitoring svc/grafana 3000:80
kubectl port-forward -n security svc/keycloak 8080:80
kubectl port-forward -n argocd svc/argocd-server 8443:443
```

## Gateway API

```bash
# GatewayClass
kubectl get gatewayclass

# Gateways
kubectl get gateways -A
kubectl describe gateway infrastructure-gateway -n nginx-gateway

# HTTPRoutes
kubectl get httproutes -A
kubectl describe httproute <name> -n <namespace>

# NGINX Gateway Fabric logs
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric

# Vérifier les listeners
kubectl get gateway infrastructure-gateway -n nginx-gateway -o jsonpath='{.status.listeners}' | jq
```

## Ressources & Monitoring

```bash
# Utilisation CPU/mémoire des nodes
kubectl top nodes

# Utilisation CPU/mémoire des pods
kubectl top pods -A
kubectl top pods -n <namespace>

# Events récents
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Décrire une ressource
kubectl describe node <node-name>
kubectl describe deployment <name> -n <namespace>
```

## Secrets

```bash
# Lister les secrets
kubectl get secrets -n <namespace>

# Voir un secret (base64)
kubectl get secret <name> -n <namespace> -o yaml

# Décoder un secret
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.<key>}' | base64 -d

# Créer un secret
kubectl create secret generic <name> -n <namespace> \
    --from-literal=key1=value1 \
    --from-literal=key2=value2
```

## ArgoCD

```bash
# Applications
kubectl get applications -n argocd
kubectl get application <name> -n argocd -o yaml

# ApplicationSets
kubectl get applicationsets -n argocd
kubectl describe applicationset <name> -n argocd

# Sync status
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# Logs des controllers
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=100
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100

# Forcer un refresh
kubectl patch application <name> -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Mot de passe admin ArgoCD
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

## PostgreSQL

```bash
# Accès CLI
kubectl exec -it postgresql-0 -n storage -- psql -U postgres

# Exécuter une requête
kubectl exec -it postgresql-0 -n storage -- psql -U postgres -c "SELECT * FROM pg_stat_activity;"

# Port-forward pour connexion locale
kubectl port-forward -n storage svc/postgresql 5432:5432

# Backups
kubectl get cronjobs -n storage
kubectl create job --from=cronjob/postgres-backup manual-backup -n storage
```

## Sealed Secrets

```bash
# Exporter le certificat
sudo ./vps/scripts/export-secrets.sh export-cert /tmp/sealed-secrets-pub.pem

# Créer un sealed secret (sur machine locale)
kubeseal --cert ~/.k3s-secrets/sealed-secrets-pub.pem < secret.yaml > sealed-secret.yaml
```

## Namespaces

```bash
# Lister
kubectl get namespaces

# Créer
kubectl create namespace <name>

# Supprimer (attention: supprime tout le contenu!)
kubectl delete namespace <name>

# Quotas d'un namespace
kubectl get resourcequotas -n <namespace>
kubectl describe resourcequota -n <namespace>
```

## Debugging

```bash
# Pod en échec - voir les events
kubectl describe pod <pod-name> -n <namespace> | grep -A 20 Events

# Pod en CrashLoopBackOff - logs précédents
kubectl logs <pod-name> -n <namespace> --previous

# Tester la connectivité réseau depuis un pod
kubectl exec -it <pod-name> -n <namespace> -- wget -qO- http://<service>.<namespace>.svc.cluster.local

# DNS resolution
kubectl exec -it <pod-name> -n <namespace> -- nslookup <service>.<namespace>.svc.cluster.local

# Vérifier les NetworkPolicies
kubectl get networkpolicies -n <namespace>
kubectl describe networkpolicy <name> -n <namespace>
```

## K3s Système

```bash
# Status K3s
systemctl status k3s

# Logs K3s
journalctl -u k3s -f
journalctl -u k3s --no-pager | tail -100

# Version
k3s --version
kubectl version

# Nodes
kubectl get nodes -o wide

# Kubeconfig
cat /etc/rancher/k3s/k3s.yaml
```

## Helm

```bash
# Releases installées
helm list -A

# Historique d'une release
helm history <release-name> -n <namespace>

# Valeurs d'une release
helm get values <release-name> -n <namespace>

# Upgrade
helm upgrade <release-name> <chart> -n <namespace> -f values.yaml

# Rollback
helm rollback <release-name> <revision> -n <namespace>
```

## Aliases utiles

Ajouter dans `~/.bashrc` ou `~/.zshrc` :

```bash
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kgs='kubectl get svc'
alias kgi='kubectl get ingress'
alias kga='kubectl get applications -n argocd'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias kd='kubectl describe'
alias ke='kubectl exec -it'
alias kpf='kubectl port-forward'
```

## Scripts k3s-stack

```bash
# Configurer le token SCM (GitHub/GitLab)
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
sudo ./vps/scripts/export-secrets.sh set-scm-credentials gitlab

# Voir les credentials
sudo ./vps/scripts/export-secrets.sh show
sudo ./vps/scripts/export-secrets.sh show grafana
sudo ./vps/scripts/export-secrets.sh show keycloak
sudo ./vps/scripts/export-secrets.sh show argocd
sudo ./vps/scripts/export-secrets.sh show <app-name>

# Exporter certificat sealed-secrets
sudo ./vps/scripts/export-secrets.sh export-cert /tmp/cert.pem

# Onboard une nouvelle application
sudo ./vps/scripts/onboard-app.sh <app-name>

# Configurer Gateway API
sudo ./vps/scripts/setup-gateway-api.sh --domain <domain>

# Configurer cert-manager
sudo ./vps/scripts/setup-cert-manager.sh --email admin@domain.com

# Générer les manifests
sudo ./vps/scripts/apply-config.sh
```
