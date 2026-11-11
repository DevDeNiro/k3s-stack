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
| IAM | Keycloak 26.8.2 | `security` | un realm par environnement |
| GitOps | Argo CD + Image Updater | `argocd` | déploiement continu depuis Git |
| Secrets versionnés | Sealed Secrets | `kube-system` | déchiffrement dans le cluster |
| Observabilité | Prometheus, Alertmanager, Loki, Alloy, Grafana | `monitoring` | métriques, alertes, logs |

Les applications sont cloisonnées entre elles : chacune a ses namespaces (Pod Security
`restricted`, quota, NetworkPolicy par défaut), son rôle PostgreSQL, son AppProject Argo CD
et ses hostnames. Un cache (Redis) se déploie dans le chart de l'application.

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
| `SCM_ORGANIZATIONS` | `my-org other-org` (une ou plusieurs organisations) |
| `REGISTRY_HOST` | `ghcr.io` (images `ghcr.io/<organisation>/<dépôt>`) |
| `LETSENCRYPT_EMAIL` | `admin@example.com` |
| `GATEWAY_HOSTNAMES` | `auth.example.com=security app.example.com=my-app-prod alpha.example.com=my-app-alpha` (hostname et namespace autorisée à le router) |
| `AUTH_HOSTNAMES` | `auth.example.com` |
| `KEYCLOAK_RATE_LIMIT_RATE`, `KEYCLOAK_RATE_LIMIT_BURST` | `10r/s`, `20` (valeurs par défaut) |
| `KEYCLOAK_EXTENSION_IMAGES` | vide, ou `ghcr.io/my-org/my-app-keycloak-theme:1.0.0` (étape 11) |
| `OFFSITE_BACKUP_REPOSITORY`, `OFFSITE_BACKUP_REGION` | `s3:https://s3.fr-par.scw.cloud/my-bucket/k3s-stack`, `fr-par` (étape 10) |

`SCM_ORGANIZATION` (une seule organisation) et `REGISTRY_BASE` (chemin d'images fixe) restent
lus pour les fichiers existants : `REGISTRY_BASE` prime sur `REGISTRY_HOST/<organisation>`
et n'est accepté qu'avec une seule organisation.

## Étape 2 : installer

```bash
sudo ./vps/install.sh
```

Environ 15 minutes. Le pare-feu est activé pendant l'installation (SSH, 80 et 443
ouverts, API Kubernetes fermée) et les mots de passe sont générés dans
`/root/.k3s-secrets/credentials.env` (`sudo ./vps/scripts/export-secrets.sh show`).
Pour ne pas installer un composant : `sudo INSTALL_LOKI=false INSTALL_ALLOY=false ./vps/install.sh`.

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
redirection HTTP vers HTTPS, les routes Keycloak avec la limite de débit de ses endpoints
OIDC, et la résolution interne des hostnames publics (les pods joignent
`https://auth.example.com` sans sortir du cluster). Il se relance après chaque modification
de `GATEWAY_HOSTNAMES`, `AUTH_HOSTNAMES` ou `KEYCLOAK_RATE_LIMIT_*`.

## Étape 5 : accès aux images et aux dépôts

```bash
sudo ./vps/scripts/export-secrets.sh set-registry-credentials     # jeton de lecture des images
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github   # jeton des dépôts
```

Deux jetons, chacun valable pour toutes les organisations de `SCM_ORGANIZATIONS`, idéalement
ceux d'un compte machine membre des organisations en lecture seule :

- le **jeton de lecture des images** est copié dans chaque namespace applicative, où tout
  chart de l'application peut le lire : token GitHub **classique** avec le seul droit
  `read:packages` (GHCR n'accepte que les tokens classiques). L'Image Updater et Keycloak
  (images d'extension privées) l'utilisent aussi ;
- le **jeton des dépôts** reste dans la namespace `argocd` : token classique avec le droit
  `repo` (un token fine-grained est limité à un seul propriétaire). Argo CD découvre alors
  les dépôts qui contiennent un dossier `helm/` (voir plus bas).

## Étape 6 : onboarder une application

```bash
sudo ./vps/scripts/onboard-app.sh my-app                              # dépôt de la première organisation
sudo ./vps/scripts/onboard-app.sh my-app --organization other-org     # dépôt d'une autre organisation
```

Pour `my-app-alpha` et `my-app-prod` (`--environment prod` pour la production seule), le
script crée :

- le namespace, avec son quota, son niveau de Pod Security (`restricted`) et sa
  NetworkPolicy par défaut ;
- le rôle et la base PostgreSQL, fermée aux autres rôles ;
- le Secret `my-app-db`, dont les URLs exigent TLS ;
- le Secret de lecture des images (`ghcr-secret`) et le Secret d'accès au dépôt ;
- en dernier, l'AppProject `my-app` : Argo CD déploie l'application dans les 3 minutes.

Une application sans base de données (client statique servi par nginx) s'onboarde avec
`--skip-database`. Les mots de passe sont conservés dans `/root/.k3s-secrets/my-app.env`. Les
routes de l'application (HTTPRoutes de son chart) s'attachent à la Gateway
`infrastructure-gateway` ; chaque hostname figure dans `GATEWAY_HOSTNAMES` avec la namespace
qui le route (`app.example.com=my-app-prod`), puis `setup-gateway-api.sh`.

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

## Étape 10 (recommandé) : sauvegardes hors site

Une copie chiffrée des dumps PostgreSQL part chaque jour vers un stockage objet compatible
S3 (restic). Créer un bucket et des clés d'accès chez le fournisseur, renseigner
`OFFSITE_BACKUP_REPOSITORY` et `OFFSITE_BACKUP_REGION` dans `vps/config.env`, puis :

```bash
sudo ./vps/scripts/setup-secrets.sh set-offsite-backup   # clés et mot de passe restic, saisis sans écho
sudo ./vps/scripts/apply-backups.sh
kubectl create job --from=cronjob/postgres-backup-offsite offsite-first -n storage
kubectl logs -n storage -l app.kubernetes.io/component=offsite -f
```

Ranger le mot de passe restic dans un gestionnaire de mots de passe : sans lui, les
sauvegardes hors site sont indéchiffrables. Restauration et exercice :
[`postgres-backup.md`](postgres-backup.md).

## Étape 11 (optionnel) : thèmes et providers Keycloak

Les images listées dans `KEYCLOAK_EXTENSION_IMAGES` apportent des thèmes (`/themes/<nom>/`)
et des providers (`/providers/*.jar`), copiés dans Keycloak à chaque démarrage :

```bash
nano vps/config.env                        # KEYCLOAK_EXTENSION_IMAGES="ghcr.io/my-org/my-app-keycloak-theme:1.0.0"
sudo ./vps/scripts/apply-keycloak.sh       # redémarre Keycloak (1 à 2 minutes)
```

Publier un nouveau tag pour chaque version : un tag déjà tiré n'est pas retéléchargé. Les
emails du realm (invitations, réinitialisations) passent par un relais SMTP sur le port 587
ou 465, autorisé par la NetworkPolicy de Keycloak.

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
(`templates/argocd/applicationsets.yaml.tpl`), avec un générateur par organisation de
`SCM_ORGANIZATIONS`. Argo CD parcourt chaque organisation et crée, pour chaque dépôt
onboardé contenant `helm/<repo>/`, l'Application `<repo>-prod` (branche `main`), et
`<repo>-alpha` (branche `develop`) seulement si le dépôt a une branche `develop` contenant
`helm/`. Un dépôt non onboardé n'a pas d'AppProject, donc pas d'Application. Le chart ne
doit contenir aucune ressource de niveau cluster (Namespace, ClusterRole, CRD...) ni
`ResourceQuota`, `LimitRange`, `Endpoints` ou `EndpointSlice`.
les annotations des Applications. Les noms de dépôt doivent être en minuscules et uniques
entre les organisations.

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
| `generated 0 applications` | pas de dossier `helm/`, token sans accès à l'organisation, ou (alpha) pas de branche `develop` |
| `application references project ... which does not exist` | application non onboardée : `onboard-app.sh <app>` |
| `... is not permitted in project` | ressource de niveau cluster, de type refusé ou d'une autre namespace dans le chart |
| `secret scm-token not found` | `export-secrets.sh set-scm-credentials` non exécuté |
| `ImagePullBackOff` | `ghcr-secret` absent : `set-registry-credentials`, puis onboarder |
| Application en double, `duplicate name` | même nom de dépôt dans deux organisations : renommer l'un des dépôts |

## Dépannage

| Symptôme | Vérification |
|----------|--------------|
| Certificat en attente | DNS propagé et port 80 joignable : `kubectl describe certificate -n nginx-gateway`, `kubectl get challenges -A` |
| Sites injoignables | `kubectl get pods,events -n nginx-gateway` (data plane `infrastructure-gateway-nginx`) |
| Keycloak : `Unable to resolve issuer` | `kubectl get configmap coredns-custom -n kube-system -o yaml` (relancer `setup-gateway-api.sh`) |
| Keycloak en `Init:ImagePullBackOff` | référence de `KEYCLOAK_EXTENSION_IMAGES` ; image privée : `set-registry-credentials`, puis `apply-keycloak.sh` |
| Route non attachée (`NotAllowedByListeners`) | namespace de la route absente de son hostname dans `GATEWAY_HOSTNAMES`, puis `setup-gateway-api.sh` |
| Pod refusé (`violates PodSecurity "restricted"`) | le chart doit tourner en non-root, sans capacité, sans escalade de privilèges, avec un profil seccomp |
| Keycloak répond `429` | augmenter `KEYCLOAK_RATE_LIMIT_RATE` / `KEYCLOAK_RATE_LIMIT_BURST` (ou `off`), puis `setup-gateway-api.sh` |
| Application sans base | label `app.kubernetes.io/managed-by=k3s-stack` du namespace, Secret `<app>-db` |
| K3s ne démarre pas | `systemctl status k3s`, `journalctl -u k3s -n 100` |

## Documentation complémentaire

- [Architecture et concepts](architecture.md)
- [Administration PostgreSQL](database-admin.md) et [sauvegardes](postgres-backup.md)
- [Observabilité](observability.md)
- [Aide-mémoire des commandes](commands-cheatsheet.md)
