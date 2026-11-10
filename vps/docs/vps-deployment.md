# Guide de déploiement VPS

Procédure guidée d'une première installation sur un VPS neuf, jusqu'au déploiement d'une
application (`my-app` dans les exemples). La référence des scripts et de leurs paramètres est
[`../README.md`](../README.md) ; la migration d'un VPS déjà installé est décrite dans
[`security-hardening.md`](security-hardening.md).

## Architecture

| Composant | Technologie | Namespace | Rôle |
| :--- | :--- | :--- | :--- |
| Runtime | K3s v1.37.2 mono-nœud, secrets chiffrés | - | Kubernetes allégé |
| Routage | Gateway API v1.6.3 + NGINX Gateway Fabric 2.8.1 | `nginx-gateway` | point d'entrée HTTP/HTTPS (hostPorts 80/443) |
| Certificats | cert-manager v1.21.3 (Let's Encrypt HTTP-01) | `cert-manager` | un certificat par hostname |
| Base de données | PostgreSQL 18 (Bitnami), TLS, SCRAM | `storage` | instance partagée, un rôle et une base par application |
| Cache | Redis 7 | `database` | sessions, rate limiting |
| IAM | Keycloak 26.8.2 | `security` | un realm par environnement |
| GitOps | Argo CD + Image Updater | `argocd` | déploiement continu depuis Git |
| Secrets versionnés | Sealed Secrets | `kube-system` | déchiffrement dans le cluster |
| Observabilité | Prometheus, Alertmanager, Loki, Promtail, Grafana | `monitoring` | métriques, alertes, logs |

## Étape 1 : préparer le serveur

1. VPS Ubuntu 24.04 (ou 22.04, Debian 12), 4 Go de RAM minimum, accès SSH par clé
   ([`workstation-setup.md`](workstation-setup.md)).
2. DNS : un enregistrement A par hostname public (`auth.example.com`, `app.example.com`,
   `alpha.example.com`…) vers l'IP du VPS.
3. Cloner le dépôt et créer la configuration :

```bash
ssh <user>@<vps>
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack
cp vps/config.env.example vps/config.env
nano vps/config.env
./vps/scripts/apply-config.sh --check
```

| Variable | Exemple |
|----------|---------|
| `SCM_PROVIDER` | `github` |
| `SCM_ORGANIZATION` | `my-org` |
| `REGISTRY_BASE` | `ghcr.io/my-org` |
| `LETSENCRYPT_EMAIL` | `admin@example.com` |
| `GATEWAY_HOSTNAMES` | `auth.example.com app.example.com alpha.example.com` |
| `AUTH_HOSTNAMES` | `auth.example.com` |

## Étape 2 : installer

```bash
sudo ./vps/install.sh
```

Environ 15 minutes. Le pare-feu est activé pendant l'installation (SSH, 80 et 443
ouverts, API Kubernetes fermée) et les mots de passe sont générés dans
`/root/.k3s-secrets/credentials.env` (`sudo ./vps/scripts/export-secrets.sh show`).
Pour ne pas installer un composant : `sudo INSTALL_LOKI=false INSTALL_PROMTAIL=false ./vps/install.sh`.

## Étape 3 : sauvegarder la clé Sealed Secrets

```bash
sudo ./vps/scripts/export-secrets.sh backup-sealing-key
# depuis le poste :
ssh <user>@<vps> 'sudo tar -C /var/backups/k3s-stack -czf - sealed-secrets' > sealed-secrets-$(date +%Y%m%d).tar.gz
```

Sans cette clé, les SealedSecrets versionnés ne pourront plus jamais être déchiffrés
après une réinstallation.

## Étape 4 : Gateway et certificats

```bash
sudo ./vps/scripts/setup-gateway-api.sh --staging   # certificats de test, sans limite de débit
kubectl get certificates -n nginx-gateway           # READY=True pour chaque hostname
sudo ./vps/scripts/setup-gateway-api.sh             # certificats de production
```

Le script crée la Gateway (un listener HTTPS par hostname), les certificats, la
redirection HTTP vers HTTPS, les routes Keycloak et la résolution interne des hostnames
publics (les pods joignent `https://auth.example.com` sans sortir du cluster). Il se
relance après chaque modification de `GATEWAY_HOSTNAMES` ou `AUTH_HOSTNAMES`.

## Étape 5 : accès aux dépôts pour Argo CD

```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

Token GitHub avec les droits `repo` et `read:packages` (ou fine-grained
`Contents: read`). Argo CD découvre alors les dépôts de l'organisation qui contiennent un
dossier `helm/` (voir plus bas).

## Étape 6 : onboarder une application

```bash
sudo ./vps/scripts/onboard-app.sh my-app
```

Pour `my-app-alpha` et `my-app-prod`, le script crée :

- le namespace, avec son quota et son niveau de Pod Security ;
- le rôle et la base PostgreSQL ;
- le Secret `my-app-db`, dont les URLs exigent TLS ;
- les Secrets d'accès à GHCR et au dépôt.

Une application sans base de données (client statique servi par nginx) s'onboarde avec
`--skip-database`. Les mots de passe sont conservés dans `/root/.k3s-secrets/my-app.env`. Les
routes de l'application (HTTPRoutes de son chart) s'attachent à la Gateway
`infrastructure-gateway` ; leurs hostnames doivent figurer dans `GATEWAY_HOSTNAMES`.

## Étape 7 : sceller les secrets de l'application (poste développeur)

```bash
# Certificat public du cluster, copié sur le poste
ssh <user>@<vps> 'sudo <chemin-du-clone>/k3s-stack/vps/scripts/export-secrets.sh export-cert ~/sealed-secrets-pub.pem'
mkdir -p ~/.k3s-secrets && scp <user>@<vps>:sealed-secrets-pub.pem ~/.k3s-secrets/sealed-secrets-pub.pem

# Une valeur chiffrée par clé de Secret, saisie sans écho (jamais en argument)
read -r -s -p "Valeur : " VALUE; echo
printf '%s' "$VALUE" | kubeseal --raw --cert ~/.k3s-secrets/sealed-secrets-pub.pem \
    --namespace my-app-alpha --name my-app-db --from-file=/dev/stdin
unset VALUE
```

Le mot de passe de base à sceller est celui de `export-secrets.sh show my-app` ; un
SealedSecret n'est déchiffrable que dans le namespace et sous le nom donnés au scellement
(avec l'annotation `sealedsecrets.bitnami.com/namespace-wide`, sceller avec
`--scope namespace-wide` et sans `--name`).
Copier les valeurs chiffrées dans `values-alpha.yaml` et `values-prod.yaml`, puis pousser.

## Étape 8 : accès depuis le poste

```bash
./vps/scripts/setup-remote.sh <vps> --user <user>
ssh -fN -L 16443:127.0.0.1:6443 <user>@<vps>
export KUBECONFIG=~/.kube/config-k3s-vps
kubectl get pods -A
```

## Étape 9 (recommandé) : durcissement SSH et alertes

```bash
# après avoir vérifié une connexion par clé dans une seconde session
sudo ./vps/scripts/harden-host.sh --apply --harden-ssh
# alertes critiques et warning vers Discord
sudo ./vps/scripts/setup-secrets.sh set-discord-webhook
```

## Stratégie IAM et données (recommandée)

### Alpha (`alpha.example.com`)
- L'application peut charger des données de démonstration au premier démarrage (profil
  ou variable d'environnement propre à l'environnement alpha).
- Un realm Keycloak `<app>-alpha` contient des comptes de test pré-validés.

### Production (`app.example.com`)
- Aucune donnée de démonstration.
- Le realm `<app>-prod` ne contient aucun compte de test.

## Auto-découverte Argo CD

L'installation configure deux ApplicationSets
(`templates/argocd/applicationsets.yaml.tpl`). Argo CD parcourt l'organisation et crée,
pour chaque dépôt contenant `helm/<repo>/`, les Applications `<repo>-alpha` (branche
`develop`) et `<repo>-prod` (branche `main`). L'Image Updater suit les nouvelles images
d'après les annotations des Applications.

Structure attendue d'un dépôt :

```text
<repo>/
  helm/
    <repo>/
      Chart.yaml
      values.yaml
      values-alpha.yaml
      values-prod.yaml
      templates/
```

Vérification :

```bash
kubectl get applicationsets,applications -n argocd
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50
```

| Problème | Cause |
|----------|-------|
| `generated 0 applications` | pas de dossier `helm/`, ou token sans accès au dépôt |
| `secret scm-token not found` | `export-secrets.sh set-scm-credentials` non exécuté |
| `ImagePullBackOff` | `ghcr-secret` absent : onboarder après `set-scm-credentials` |

## Dépannage

| Symptôme | Vérification |
|----------|--------------|
| Certificat en attente | DNS propagé et port 80 joignable : `kubectl describe certificate -n nginx-gateway`, `kubectl get challenges -A` |
| Sites injoignables | `kubectl get pods,events -n nginx-gateway` (data plane `infrastructure-gateway-nginx`) |
| Keycloak : `Unable to resolve issuer` | `kubectl get configmap coredns-custom -n kube-system -o yaml` (relancer `setup-gateway-api.sh`) |
| Application sans base | label `app.kubernetes.io/managed-by=k3s-stack` du namespace, Secret `<app>-db` |
| K3s ne démarre pas | `systemctl status k3s`, `journalctl -u k3s -n 100` |

## Documentation complémentaire

- [Architecture et concepts](architecture.md)
- [Administration PostgreSQL](database-admin.md) et [sauvegardes](postgres-backup.md)
- [Observabilité](observability.md)
- [Aide-mémoire des commandes](commands-cheatsheet.md)
